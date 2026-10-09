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
    exercise_update(false, false);
}

#[cfg(windows)]
#[test]
fn interactive_update_keeps_the_original_windows_console() {
    exercise_update(true, false);
}

#[test]
fn update_from_an_older_release_accepts_its_restart_arguments() {
    exercise_update(false, true);
}

fn exercise_update(interactive: bool, legacy: bool) {
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
            if let Some(ready) = std::env::args().nth(1) {
                let ready = std::path::Path::new(&ready);
                let root = ready.parent().unwrap().parent().unwrap();
                std::fs::write(root.join("parent.pid"), std::process::id().to_string()).unwrap();
                let start = std::time::Instant::now();
                while !ready.exists() {
                    assert!(start.elapsed().as_secs() < 15);
                    std::thread::sleep(std::time::Duration::from_millis(25));
                }
            }
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
        .prefix(".micropython-esp-flasher-update-")
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
    let mut parent = if interactive {
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            Command::new("pwsh.exe")
                .args(["-NoProfile", "-Command", "$p = Start-Process -FilePath $env:MICROPYTHON_ESP_FLASHER_TEST_EXE -ArgumentList ('\"' + $env:MICROPYTHON_ESP_FLASHER_TEST_READY + '\"') -WindowStyle Hidden -PassThru; $p.WaitForExit(); exit $p.ExitCode"])
                .env("MICROPYTHON_ESP_FLASHER_TEST_EXE", &target)
                .env("MICROPYTHON_ESP_FLASHER_TEST_READY", stage.path().join("ready"))
                .creation_flags(0x0800_0000)
                .spawn()
                .unwrap()
        }
        #[cfg(not(windows))]
        unreachable!("The console test is Windows-only")
    } else {
        Command::new(&target).spawn().unwrap()
    };
    let parent_pid = if interactive {
        let started = Instant::now();
        let path = root.path().join("parent.pid");
        loop {
            if let Ok(text) = fs::read_to_string(&path)
                && let Ok(pid) = text.parse::<u32>()
            {
                break pid;
            }
            assert!(started.elapsed() < Duration::from_secs(10));
            thread::sleep(Duration::from_millis(25));
        }
    } else {
        parent.id()
    };
    let old_hash = hash(&target);
    let new_hash = hash(&candidate);
    let args = if legacy {
        vec!["--no-self-update", "--version"]
    } else {
        vec!["--version"]
    };
    let request = serde_json::json!({
        "target": fs::canonicalize(&target).unwrap(), "parent_pid": parent_pid,
        "version": env!("CARGO_PKG_VERSION"), "previous_version": "0.4.0",
        "previous_digest": old_hash, "new_digest": new_hash,
        "args": args, "working_dir": root.path(), "interactive": interactive
    });
    fs::write(
        stage.path().join("request.json"),
        serde_json::to_vec(&request).unwrap(),
    )
    .unwrap();
    let mut helper_command = Command::new(&candidate);
    helper_command
        .arg("--internal-apply-update")
        .arg(stage.path());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        helper_command.creation_flags(0x0800_0000);
    }
    let mut helper = helper_command.spawn().unwrap();
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
