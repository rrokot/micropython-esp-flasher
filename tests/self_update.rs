use sha2::{Digest, Sha256};
use std::{
    fs,
    process::Command,
    thread,
    time::{Duration, Instant},
};

fn hash(path: &std::path::Path) -> String {
    use std::fmt::Write;
    Sha256::digest(fs::read(path).unwrap()).iter().fold(
        String::with_capacity(64),
        |mut text, byte| {
            write!(text, "{byte:02x}").unwrap();
            text
        },
    )
}

#[test]
fn helper_waits_for_the_running_program_replaces_it_and_restarts() {
    let root = tempfile::tempdir().unwrap();
    let exe = if cfg!(windows) {
        "micropython-esp-flasher.exe"
    } else {
        "micropython-esp-flasher"
    };
    let target = root.path().join(exe);
    let fixture = root.path().join("parent.rs");
    fs::write(
        &fixture,
        r#"fn main() {
        if std::env::args().any(|arg| arg == "--version") {
            println!("micropython-esp-flasher 0.4.0");
        } else {
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    }"#,
    )
    .unwrap();
    let mut compiler = Command::new("rustc");
    compiler
        .arg(&fixture)
        .arg("--edition=2024")
        .arg("-o")
        .arg(&target);
    if cfg!(windows) {
        compiler.args(["-C", "target-feature=+crt-static"]);
    }
    assert!(compiler.status().unwrap().success());
    fs::write(root.path().join("LICENSE"), b"old-license").unwrap();
    fs::write(
        root.path().join("THIRD-PARTY-LICENSES.html"),
        b"old-notices",
    )
    .unwrap();
    fs::create_dir(root.path().join("firmware")).unwrap();
    fs::write(root.path().join("firmware/board.bin"), b"keep-firmware").unwrap();
    let stage = tempfile::Builder::new()
        .prefix(".mpflash-update-")
        .tempdir_in(root.path())
        .unwrap();
    let candidate = stage.path().join(exe);
    fs::copy(env!("CARGO_BIN_EXE_micropython-esp-flasher"), &candidate).unwrap();
    fs::write(stage.path().join("LICENSE"), b"new-license").unwrap();
    fs::write(
        stage.path().join("THIRD-PARTY-LICENSES.html"),
        b"new-notices",
    )
    .unwrap();
    let mut parent = Command::new(&target).spawn().unwrap();
    let old_hash = hash(&target);
    let new_hash = hash(&candidate);
    let request = serde_json::json!({
        "target": fs::canonicalize(&target).unwrap(), "parent_pid": parent.id(),
        "version": env!("CARGO_PKG_VERSION"), "previous_version": "0.4.0",
        "previous_digest": old_hash, "new_digest": new_hash,
        "args": ["--version"], "working_dir": root.path(), "interactive": false
    });
    fs::write(
        stage.path().join("request.json"),
        serde_json::to_vec(&request).unwrap(),
    )
    .unwrap();
    let mut helper = Command::new(&candidate)
        .arg("--internal-apply-update")
        .arg(stage.path())
        .spawn()
        .unwrap();
    thread::sleep(Duration::from_millis(200));
    assert_eq!(
        hash(&target),
        old_hash,
        "The program must not change while its parent is running"
    );
    assert!(parent.wait().unwrap().success());
    assert!(helper.wait().unwrap().success());
    assert_eq!(hash(&target), new_hash);
    assert_eq!(
        fs::read(root.path().join("LICENSE")).unwrap(),
        b"new-license"
    );
    assert_eq!(
        fs::read(root.path().join("THIRD-PARTY-LICENSES.html")).unwrap(),
        b"new-notices"
    );
    assert_eq!(
        fs::read(root.path().join("firmware/board.bin")).unwrap(),
        b"keep-firmware"
    );
    let started = Instant::now();
    while stage.path().exists() && started.elapsed() < Duration::from_secs(10) {
        thread::sleep(Duration::from_millis(25));
    }
    assert!(
        !stage.path().exists(),
        "The restarted program must clean its update files"
    );
    assert!(
        Command::new(&target)
            .arg("--version")
            .status()
            .unwrap()
            .success()
    );
}

#[test]
fn offline_update_returns_before_connecting_to_any_board() {
    let root = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_micropython-esp-flasher"))
        .arg("--data-dir")
        .arg(root.path())
        .args(["--port", "NOT-A-PORT", "--offline", "self-update"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stdout)
            .contains("Tool updates are disabled in offline mode")
    );
}
