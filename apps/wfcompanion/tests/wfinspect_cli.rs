use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "wfinspect-cli-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn capture(
        &self,
        path: &str,
        base: u64,
        permissions: &str,
        name: &str,
        bytes: &[u8],
    ) -> PathBuf {
        let directory = self.0.join(path);
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("scaleform-memory.bin"), bytes).unwrap();
        fs::write(
            directory.join("maps.txt"),
            format!(
                "{base:x}-{:x} {permissions} 0 00:00 0 {name}\n",
                base + bytes.len() as u64
            ),
        )
        .unwrap();
        fs::write(directory.join("ui.json"), serde_json::to_vec(&json!({
            "schema": 2, "captured_at_unix_ms": 123,
            "snapshot": { "pid": 42, "movies": [{ "path": "/Lotus/Interface/Old.swf", "record_address": base, "path_address": base, "width": 2560, "height": 1440, "scale_x": 1.0, "scale_y": 1.0 }] },
            "memory": {
                "file": "scaleform-memory.bin", "block_size": 512, "max_depth": 6,
                "max_blocks": 65536, "max_blocks_per_root": 1024, "max_children_per_block": 48,
                "bytes": bytes.len(), "truncated": false, "roots": [],
                "blocks": [{ "address": base, "length": bytes.len(), "file_offset": 0, "depth": 0, "permissions": permissions, "region": name }],
            },
        })).unwrap()).unwrap();
        directory
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(args: &[&str], capture: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_wfinspect"));
    command.args(args);
    if let Some(capture) = capture {
        command.arg("--capture").arg(capture);
    }
    command.output().unwrap()
}

fn document(output: Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn copy_executable(source: &Path, destination: &Path) {
    // Other test threads may fork; do not let them inherit a writable executable FD.
    assert!(
        Command::new("cp")
            .arg(source)
            .arg(destination)
            .status()
            .unwrap()
            .success()
    );
}

fn await_path(path: &Path) {
    for _ in 0..500 {
        if path.exists() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    panic!("timed out waiting for {}", path.display());
}

#[test]
fn helper_prefix_survives_directory_exchange() {
    if let Some(root) = std::env::var_os("WFCLI_TEST_MOVED_PREFIX") {
        let root = PathBuf::from(root);
        let initial = wfcompanion::executable_path().unwrap().to_owned();
        fs::write(root.join("ready"), "").unwrap();
        await_path(&root.join("continue"));
        assert_ne!(std::env::current_exe().unwrap(), initial);
        assert_eq!(wfcompanion::executable_path().unwrap(), initial);
        assert!(initial.parent().unwrap().join("helper").is_file());
        return;
    }
    let fixture = Fixture::new();
    let prefix = fixture.0.join("prefix");
    fs::create_dir_all(prefix.join("bin")).unwrap();
    let executable = prefix.join("bin/test");
    copy_executable(&std::env::current_exe().unwrap(), &executable);
    let mut child = Command::new(&executable)
        .args([
            "--exact",
            "helper_prefix_survives_directory_exchange",
            "--nocapture",
        ])
        .env("WFCLI_TEST_MOVED_PREFIX", &fixture.0)
        .spawn()
        .unwrap();
    await_path(&fixture.0.join("ready"));
    fs::rename(&prefix, fixture.0.join("retired")).unwrap();
    fs::create_dir_all(prefix.join("bin")).unwrap();
    fs::write(prefix.join("bin/helper"), "replacement").unwrap();
    fs::write(fixture.0.join("continue"), "").unwrap();
    assert!(child.wait().unwrap().success());
}

#[test]
fn bundled_decoder_is_relocatable_and_explicit_overrides_win() {
    let fixture = Fixture::new();
    let bin = fixture.0.join("bin");
    let libexec = fixture.0.join("libexec");
    fs::create_dir(&bin).unwrap();
    fs::create_dir(&libexec).unwrap();
    let executable = bin.join("wfinspect");
    copy_executable(Path::new(env!("CARGO_BIN_EXE_wfinspect")), &executable);
    let helper = libexec.join("unoodle");
    fs::write(&helper, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();

    let mut command = Command::new(&executable);
    command
        .args(["game", "cache", "decoder"])
        .env("PATH", &bin)
        .env_remove("WFINSPECT_OODLE_LIBRARY")
        .env_remove("WFINSPECT_OODLE_COMMAND");
    let report = document(command.output().unwrap());
    assert_eq!(report["available"], true);
    assert_eq!(report["source"], helper.to_str().unwrap());

    command.env("WFINSPECT_OODLE_COMMAND", fixture.0.join("missing"));
    let report = document(command.output().unwrap());
    assert_eq!(report["available"], false);
    assert!(
        report["error"]
            .as_str()
            .unwrap()
            .contains("WFINSPECT_OODLE_COMMAND")
    );

    command.env_remove("WFINSPECT_OODLE_COMMAND");
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o644)).unwrap();
    let report = document(command.output().unwrap());
    assert_eq!(report["available"], false);
    assert!(report["error"].as_str().unwrap().contains("not executable"));
}

#[test]
fn cli_help_validation_completion_and_literals() {
    let help = run(
        &["game", "cache", "paths", "/absent", "Font", "--help"],
        None,
    );
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage:"));
    for args in [
        vec!["game", "memory", "scan", "a\u{20ac}"],
        vec!["game", "ui", "find", "--mistyped"],
    ] {
        let output = run(&args, None);
        assert_eq!(output.status.code(), Some(2));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("panicked"));
    }
    let completion = run(&["completion", "bash"], None);
    assert!(completion.status.success());
    assert!(String::from_utf8_lossy(&completion.stdout).contains("wfinspect"));
    assert!(
        document(run(&["game", "adapter", "--list"], None))
            .as_array()
            .unwrap()
            .len()
            > 0
    );
    let fixture = Fixture::new();
    let path = fixture.capture("literal", 0x1000, "rw-p", "[heap]", b"literal help text\0");
    let output = run(
        &[
            "game",
            "ui",
            "find",
            "--capture",
            path.to_str().unwrap(),
            "--",
            "help",
        ],
        None,
    );
    assert_eq!(document(output)["text"]["terms"][0]["term"], "help");
}

#[test]
fn pointers_use_image_roots_and_report_exhausted_depth() {
    let fixture = Fixture::new();
    let mut bytes = vec![0; 8192];
    for index in 0..20 {
        bytes[index * 256..index * 256 + 8]
            .copy_from_slice(&(0x1000 + (index as u64 + 1) * 256).to_le_bytes());
    }
    let path = fixture.capture("chain", 0x1000, "r--p", "/game/Warframe.x64.exe", &bytes);
    let short = document(run(
        &[
            "game",
            "memory",
            "path",
            "0x1000",
            "0x1100",
            "--block-size",
            "8",
        ],
        Some(&path),
    ));
    assert_eq!(short["path"]["hops"].as_array().unwrap().len(), 1);
    let limited = document(run(
        &[
            "game",
            "memory",
            "path",
            "0x1000",
            "0x2300",
            "--block-size",
            "8",
        ],
        Some(&path),
    ));
    assert_eq!(limited["path"]["coverage"]["depth_limited"], true);
    assert_eq!(limited["path"]["truncated"], true);
    let found = document(run(
        &[
            "game",
            "memory",
            "path",
            "0x1000",
            "0x2300",
            "--depth",
            "24",
            "--block-size",
            "8",
        ],
        Some(&path),
    ));
    assert_eq!(found["path"]["hops"].as_array().unwrap().len(), 19);
    assert!(
        !run(&["game", "memory", "path", "0xffff", "0x1100"], Some(&path))
            .status
            .success()
    );
}

#[test]
fn scan_scope_and_coverage_are_explicit() {
    let fixture = Fixture::new();
    let path = fixture.capture(
        "mapped",
        0x1000,
        "r--p",
        "/game/resource.cache",
        b"xxmarkerxx",
    );
    let default = document(run(&["game", "memory", "find", "marker"], Some(&path)));
    assert_eq!(default["searched_bytes"], 0);
    let readable = document(run(
        &["game", "memory", "find", "marker", "--scope", "readable"],
        Some(&path),
    ));
    assert_eq!(readable["matches"][0]["address"], 0x1002);
    let raw = run(&["game", "memory", "read", "0x1002", "6"], Some(&path));
    assert!(raw.status.success());
    assert_eq!(raw.stdout, b"marker");
    let bulk = fixture.capture("bulk", 0x1000, "rw-p", "[heap]", &vec![0; 8 * 1024 * 1024]);
    let scanned = document(run(&["game", "memory", "scan", "00"], Some(&bulk)));
    assert_eq!(scanned["searched_bytes"], 4096);
    assert_eq!(scanned["candidate_bytes"], 8 * 1024 * 1024);
    assert_eq!(scanned["coverage"]["match_limited"], true);
}

#[test]
fn selected_capture_roundtrips_and_never_overwrites() {
    let fixture = Fixture::new();
    let source = fixture.capture("source", 0x1000, "rw-p", "[heap]", b"0123456789abcdef");
    let output = fixture.0.join("selected");
    let args = [
        "game",
        "memory",
        "capture",
        output.to_str().unwrap(),
        "--range",
        "0x1004:8",
    ];
    let captured = document(run(&args, Some(&source)));
    assert_eq!(captured["bytes"], 8);
    assert_eq!(
        run(&["game", "memory", "read", "0x1004", "8"], Some(&output)).stdout,
        b"456789ab"
    );
    assert!(!run(&args, Some(&source)).status.success());
}

#[test]
fn movies_recompute_instead_of_reusing_saved_snapshot() {
    let fixture = Fixture::new();
    let path = fixture.capture("old", 0x1000, "rw-p", "[heap]", &vec![0; 512]);
    let report = document(run(&["game", "ui", "movies"], Some(&path)));
    assert!(report["snapshot"]["movies"].as_array().unwrap().is_empty());
    assert!(report["metrics"].is_object());
}

#[test]
fn cache_search_retains_matches_before_error_and_streams_them() {
    let fixture = Fixture::new();
    let mut toc = vec![0; 8];
    let data = b"xxneedle-needle";
    for (offset, size, name) in [
        (0_i64, data.len() as i32, "First.bin"),
        (data.len() as i64, 100, "Broken.bin"),
    ] {
        let mut entry = [0; 96];
        entry[..8].copy_from_slice(&offset.to_le_bytes());
        entry[16..20].copy_from_slice(&size.to_le_bytes());
        entry[20..24].copy_from_slice(&size.to_le_bytes());
        entry[32..32 + name.len()].copy_from_slice(name.as_bytes());
        toc.extend_from_slice(&entry);
    }
    fs::write(fixture.0.join("H.Probe.toc"), toc).unwrap();
    fs::write(fixture.0.join("H.Probe.cache"), data).unwrap();
    let output = run(
        &[
            "game",
            "cache",
            "find",
            fixture.0.to_str().unwrap(),
            "Probe",
            "needle",
            "--stream",
        ],
        None,
    );
    assert!(!output.status.success());
    let records: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(records[1]["data"]["offset"], 2);
    assert_eq!(records[2]["data"]["offset"], 9);
    assert_eq!(records[3]["data"]["kind"], "error");
    assert_eq!(records.last().unwrap()["data"]["errors"], 1);
    assert_eq!(records.last().unwrap()["data"]["matches"], 2);
}

#[test]
fn rejected_daemon_request_exits_nonzero_and_preserves_reply() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    let fixture = Fixture::new();
    let socket = fixture.0.join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["op"], "hello");
        stream
            .write_all(b"{\"ok\":true,\"compatible\":true}\n")
            .unwrap();
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["op"], "get");
        stream
            .write_all(b"{\"ok\":false,\"error\":\"unsupported_dataset\"}\n")
            .unwrap();
    });
    let output = Command::new(env!("CARGO_BIN_EXE_wfinspect"))
        .args(["daemon", "get", "invalid"])
        .env("WFCLI_DAEMON_SOCKET", socket)
        .output()
        .unwrap();
    server.join().unwrap();
    assert!(!output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["response"]["error"],
        "unsupported_dataset"
    );
}
