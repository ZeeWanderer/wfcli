use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const BLEND2D_SOURCE: &str = "vendor/blend2d";
const ASMJIT_SOURCE: &str = "vendor/asmjit";

fn main() {
    println!("cargo:rerun-if-changed=native");
    println!("cargo:rerun-if-changed={BLEND2D_SOURCE}");
    println!("cargo:rerun-if-changed={ASMJIT_SOURCE}");
    println!("cargo:rerun-if-env-changed=WFCLI_CPU_BASELINE");

    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let version_file = manifest_dir.join("../../VERSION");
    let version = fs::read_to_string(&version_file)
        .expect("read root VERSION")
        .trim()
        .to_owned();
    assert_eq!(
        version,
        env::var("CARGO_PKG_VERSION").unwrap(),
        "apps/wfcompanion/Cargo.toml version must match root VERSION"
    );
    println!("cargo:rerun-if-changed={}", version_file.display());
    println!("cargo:rustc-env=WFCLI_VERSION={version}");

    let blend2d_dir = manifest_dir.join(BLEND2D_SOURCE);
    let asmjit_dir = manifest_dir.join(ASMJIT_SOURCE);
    require_submodule(&blend2d_dir, "Blend2D");
    require_submodule(&asmjit_dir, "AsmJit");

    let build_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("native");
    let mut configure = Command::new("cmake");
    configure
        .arg("-S")
        .arg(manifest_dir.join("native"))
        .arg("-B")
        .arg(&build_dir)
        .arg("-DCMAKE_BUILD_TYPE=Release")
        .arg("-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
        .arg(format!("-DBLEND2D_DIR={}", blend2d_dir.display()))
        .arg(format!("-DASMJIT_DIR={}", asmjit_dir.display()));
    let cpu = env::var_os("WFCLI_CPU_BASELINE").unwrap_or_default();
    configure.arg(format!(
        "-DWFCOMPANION_CPU_BASELINE={}",
        cpu.to_string_lossy()
    ));
    run(&mut configure, "configure native renderer");
    run(
        Command::new("cmake")
            .arg("--build")
            .arg(&build_dir)
            .arg("--config")
            .arg("Release")
            .arg("--target")
            .arg("wfcompanion_blend2d_bridge")
            .arg("--parallel"),
        "build native renderer",
    );

    println!(
        "cargo:rustc-link-search=native={}",
        build_dir.join("lib").display()
    );
    println!("cargo:rustc-link-lib=static=wfcompanion_blend2d_bridge");
    println!("cargo:rustc-link-lib=static=blend2d");
    println!("cargo:rustc-link-lib=dylib=stdc++");
    println!("cargo:rustc-link-lib=dylib=pthread");
    println!("cargo:rustc-link-lib=dylib=dl");
    println!("cargo:rustc-link-lib=dylib=m");
}

fn require_submodule(path: &Path, name: &str) {
    assert!(
        path.join("CMakeLists.txt").is_file(),
        "{name} submodule is missing; run `git submodule update --init`"
    );
}

fn run(command: &mut Command, action: &str) {
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("could not {action}: {error}"));
    assert!(status.success(), "could not {action}: {status}");
}
