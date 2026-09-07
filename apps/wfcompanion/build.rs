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

    let protocol_file = manifest_dir.join("../wfdaemon/src/runtime/wfcli_local_protocol.erl");
    let protocol_source = fs::read_to_string(&protocol_file).expect("read wfdaemon local protocol");
    let interfaces = protocol_interfaces(&protocol_source);
    let mut generated_protocol = format!(
        "pub const ENVELOPE_VERSION: u32 = {};\n",
        protocol_define(&protocol_source, "ENVELOPE_VERSION")
    );
    for (constant, _, version) in &interfaces {
        generated_protocol.push_str(&format!("pub const {constant}: u32 = {version};\n"));
    }
    generated_protocol.push_str("pub const INTERFACES: &[(&str, u32)] = &[\n");
    for (_, name, version) in &interfaces {
        generated_protocol.push_str(&format!("    (\"{name}\", {version}),\n"));
    }
    generated_protocol.push_str("];\n");
    println!("cargo:rerun-if-changed={}", protocol_file.display());
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::write(out_dir.join("local_protocol.rs"), generated_protocol)
        .expect("write generated local protocol constants");

    let blend2d_dir = manifest_dir.join(BLEND2D_SOURCE);
    let asmjit_dir = manifest_dir.join(ASMJIT_SOURCE);
    require_submodule(&blend2d_dir, "Blend2D");
    require_submodule(&asmjit_dir, "AsmJit");

    let build_dir = out_dir.join("native");
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

fn protocol_define(source: &str, name: &str) -> u32 {
    source
        .lines()
        .find_map(|line| {
            line.strip_prefix(&format!("-define({name},"))
                .and_then(|value| value.strip_suffix(")."))
                .and_then(|value| value.trim().parse().ok())
        })
        .unwrap_or_else(|| panic!("parse wfdaemon protocol define {name}"))
}

fn protocol_interfaces(source: &str) -> Vec<(String, String, u32)> {
    source
        .lines()
        .filter_map(|line| {
            let value = line.strip_prefix("-define(INTERFACE_")?;
            let (name, version) = value.strip_suffix(").")?.split_once(',')?;
            let constant = format!("INTERFACE_{}", name.trim());
            let wire_name = name.trim().to_ascii_lowercase();
            let version = version.trim().parse().ok()?;
            Some((constant, wire_name, version))
        })
        .collect()
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
