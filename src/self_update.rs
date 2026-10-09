use anyhow::{Context, Result, bail, ensure};
use flate2::read::GzDecoder;
use reqwest::blocking::Client;
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::{Builder, TempDir};

const REPOSITORY: &str = "rrokot/micropython-esp-flasher";
const LATEST: &str = "https://api.github.com/repos/rrokot/micropython-esp-flasher/releases/latest";
const PREFIX: &str = ".mpflash-update-";
const APPLY: &str = "--internal-apply-update";
const FINISH: &str = "--internal-finish-update";
const NOTICE: &str = "THIRD-PARTY-LICENSES.html";
const REQUEST: &str = "request.json";
const MAX_DOWNLOAD: u64 = 64 * 1024 * 1024;
const MAX_UNPACKED: u64 = 128 * 1024 * 1024;
const MAX_JSON: u64 = 1024 * 1024;
const EXE: &str = if cfg!(windows) {
    "micropython-esp-flasher.exe"
} else {
    "micropython-esp-flasher"
};

#[derive(Debug, Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<Asset>,
}

#[derive(Clone, Debug, Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    size: u64,
    digest: Option<String>,
    state: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Request {
    target: PathBuf,
    parent_pid: u32,
    version: String,
    previous_version: String,
    previous_digest: String,
    new_digest: String,
    args: Vec<String>,
    working_dir: PathBuf,
    interactive: bool,
    #[serde(default)]
    error: Option<String>,
}

fn package_name(version: &Version, os: &str, arch: &str) -> Result<String> {
    let arch = match arch {
        "x86_64" => "x64",
        "aarch64" => "arm64",
        _ => bail!("No tool update is available for {os}/{arch}"),
    };
    let extension = match (os, arch) {
        ("windows", "x64") => "zip",
        ("linux" | "macos", _) => "tar.gz",
        _ => bail!("No tool update is available for {os}/{arch}"),
    };
    Ok(format!(
        "micropython-esp-flasher-v{version}-{os}-{arch}.{extension}"
    ))
}

fn select_asset(
    release: Release,
    current: &Version,
    os: &str,
    arch: &str,
) -> Result<Option<(Version, Asset)>> {
    ensure!(
        !release.draft && !release.prerelease,
        "The latest tool release is not stable"
    );
    let version = Version::parse(
        release
            .tag_name
            .strip_prefix('v')
            .unwrap_or(&release.tag_name),
    )?;
    ensure!(
        version.pre.is_empty() && version.build.is_empty(),
        "The tool release tag is not stable"
    );
    if version <= *current {
        return Ok(None);
    }
    let name = package_name(&version, os, arch)?;
    let mut matches = release
        .assets
        .into_iter()
        .filter(|asset| asset.name == name);
    let asset = matches
        .next()
        .context("The release has no archive for this platform")?;
    ensure!(
        matches.next().is_none(),
        "The tool release contains duplicate archives"
    );
    ensure!(
        asset.state == "uploaded" && asset.size > 0 && asset.size <= MAX_DOWNLOAD,
        "The tool archive is unavailable or too large"
    );
    let expected_url = format!(
        "https://github.com/{REPOSITORY}/releases/download/{}/{name}",
        release.tag_name
    );
    ensure!(
        asset.browser_download_url == expected_url,
        "The tool archive URL does not belong to this release"
    );
    parse_digest(
        asset
            .digest
            .as_deref()
            .context("The tool archive has no SHA-256 digest")?,
    )?;
    Ok(Some((version, asset)))
}

fn parse_digest(text: &str) -> Result<String> {
    let hash = text
        .strip_prefix("sha256:")
        .context("Unsupported archive digest")?;
    ensure!(
        hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()),
        "Invalid SHA-256 digest"
    );
    Ok(hash.to_ascii_lowercase())
}

fn bounded_read(reader: impl Read, limit: u64) -> Result<Vec<u8>> {
    let mut data = Vec::new();
    reader.take(limit + 1).read_to_end(&mut data)?;
    ensure!(
        data.len() as u64 <= limit,
        "Response exceeds its size limit"
    );
    Ok(data)
}

fn fetch_release(client: &Client, url: &str) -> Result<Release> {
    let response = client
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(5))
        .send()?
        .error_for_status()?;
    Ok(serde_json::from_slice(&bounded_read(response, MAX_JSON)?)?)
}

fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn download(client: &Client, asset: &Asset, destination: &Path) -> Result<()> {
    ensure!(
        asset.size > 0 && asset.size <= MAX_DOWNLOAD,
        "Invalid archive download size"
    );
    let expected = parse_digest(asset.digest.as_deref().context("Missing archive digest")?)?;
    let response = client
        .get(&asset.browser_download_url)
        .send()?
        .error_for_status()?;
    ensure!(
        response
            .content_length()
            .is_none_or(|size| size == asset.size),
        "Incorrect archive download size"
    );
    let mut file = File::create_new(destination)?;
    let written = io::copy(&mut response.take(asset.size + 1), &mut file)?;
    ensure!(written == asset.size, "Incomplete tool archive download");
    file.sync_all()?;
    ensure!(
        hash_file(destination)? == expected,
        "Tool archive SHA-256 mismatch"
    );
    Ok(())
}

fn wanted_entry(name: &[u8]) -> Option<&'static str> {
    [EXE, "LICENSE", NOTICE]
        .into_iter()
        .find(|file| name == format!("micropython-esp-flasher/{file}").as_bytes())
}

fn save_entry(
    reader: impl Read,
    size: u64,
    stage: &Path,
    name: &str,
    seen: &mut Vec<String>,
) -> Result<()> {
    ensure!(
        !seen.iter().any(|file| file == name),
        "Duplicate file in tool archive: {name}"
    );
    ensure!(
        size > 0 && size <= MAX_UNPACKED,
        "Invalid tool archive entry size"
    );
    let mut file = File::create_new(stage.join(name))?;
    let count = io::copy(&mut reader.take(size + 1), &mut file)?;
    ensure!(count == size, "Incomplete tool archive entry: {name}");
    file.sync_all()?;
    seen.push(name.to_owned());
    Ok(())
}

fn unpack(archive: &Path, zip: bool, stage: &Path) -> Result<()> {
    let mut seen = Vec::new();
    if zip {
        let mut total = 0u64;
        let mut archive = zip::ZipArchive::new(File::open(archive)?)?;
        ensure!(archive.len() <= 128, "Too many files in tool archive");
        for index in 0..archive.len() {
            let entry = archive.by_index(index)?;
            if let Some(name) = wanted_entry(entry.name_raw()) {
                ensure!(
                    entry.is_file()
                        && entry
                            .unix_mode()
                            .is_none_or(|mode| mode & 0o170000 == 0 || mode & 0o170000 == 0o100000),
                    "Tool archive contains a link or a directory"
                );
                let size = entry.size();
                total = total.saturating_add(size);
                ensure!(total <= MAX_UNPACKED, "Unpacked tool archive is too large");
                save_entry(entry, size, stage, name, &mut seen)?;
            }
        }
    } else {
        let reader = GzDecoder::new(File::open(archive)?).take(MAX_UNPACKED);
        let mut archive = tar::Archive::new(reader);
        for (index, entry) in archive.entries()?.enumerate() {
            ensure!(index < 128, "Too many files in tool archive");
            let entry = entry?;
            if let Some(name) = wanted_entry(&entry.path_bytes()) {
                ensure!(
                    entry.header().entry_type().is_file(),
                    "Tool archive contains a link or a directory"
                );
                let size = entry.size();
                save_entry(entry, size, stage, name, &mut seen)?;
            }
        }
    }
    ensure!(
        seen.len() == 3,
        "Tool archive must contain the program and both license files"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(stage.join(EXE), fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

fn hidden(command: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    command
}

fn check_binary(path: &Path, expected: &str) -> Result<()> {
    let mut command = Command::new(path);
    hidden(&mut command)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = command
        .spawn()
        .context("The new tool executable cannot start")?;
    let start = Instant::now();
    while child.try_wait()?.is_none() {
        if start.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            bail!("The new tool executable did not answer");
        }
        thread::sleep(Duration::from_millis(25));
    }
    let output = child.wait_with_output()?;
    ensure!(
        output.status.success()
            && String::from_utf8_lossy(&output.stdout).trim()
                == format!("micropython-esp-flasher {expected}"),
        "The new executable does not match the release version"
    );
    Ok(())
}

fn regular_or_missing(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            metadata.file_type().is_file(),
            "Update destination is not a regular file: {}",
            path.display()
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

fn save_request(stage: &Path, request: &Request) -> Result<()> {
    let mut file = File::create(stage.join(REQUEST))?;
    file.write_all(&serde_json::to_vec(request)?)?;
    file.sync_all()?;
    Ok(())
}

fn read_request(stage: &Path) -> Result<Request> {
    ensure!(
        !fs::symlink_metadata(stage)?.file_type().is_symlink(),
        "The update folder must not be a link"
    );
    let stage = fs::canonicalize(stage)?;
    ensure!(
        stage
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with(PREFIX)),
        "Invalid update folder name"
    );
    regular_or_missing(&stage.join(REQUEST))?;
    let request: Request =
        serde_json::from_slice(&bounded_read(File::open(stage.join(REQUEST))?, MAX_JSON)?)?;
    ensure!(
        request.target.is_absolute(),
        "The update target must be absolute"
    );
    let parent = request
        .target
        .parent()
        .context("Missing update target folder")?;
    ensure!(
        stage.parent() == Some(fs::canonicalize(parent)?.as_path()),
        "Update folder is outside the program folder"
    );
    ensure!(
        request
            .target
            .file_name()
            .is_some_and(|name| name != "LICENSE" && name != NOTICE),
        "Invalid program filename"
    );
    Version::parse(&request.version)?;
    Version::parse(&request.previous_version)?;
    parse_digest(&format!("sha256:{}", request.new_digest))?;
    parse_digest(&format!("sha256:{}", request.previous_digest))?;
    Ok(request)
}

pub fn update(args: Vec<String>, interactive: bool, mut report: impl FnMut(&str)) -> Result<bool> {
    report("Checking GitHub for a new tool version");
    let client = Client::builder()
        .https_only(true)
        .user_agent(concat!(
            "micropython-esp-flasher/",
            env!("CARGO_PKG_VERSION")
        ))
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(180))
        .build()?;
    let current = Version::parse(env!("CARGO_PKG_VERSION"))?;
    let release = fetch_release(&client, LATEST)?;
    let Some((version, asset)) = select_asset(
        release,
        &current,
        std::env::consts::OS,
        std::env::consts::ARCH,
    )?
    else {
        report("The tool is up to date");
        return Ok(false);
    };
    let target = fs::canonicalize(std::env::current_exe()?)?;
    let parent = target.parent().context("Missing program folder")?;
    for path in [target.clone(), parent.join("LICENSE"), parent.join(NOTICE)] {
        regular_or_missing(&path)?;
    }
    let stage = Builder::new()
        .prefix(PREFIX)
        .tempdir_in(parent)
        .context("The program folder is not writable")?;
    report(&format!("Downloading tool version {version}"));
    let archive = stage.path().join("release.archive");
    download(&client, &asset, &archive)?;
    unpack(&archive, asset.name.ends_with(".zip"), stage.path())?;
    check_binary(&stage.path().join(EXE), &version.to_string())?;
    let request = Request {
        previous_digest: hash_file(&target)?,
        new_digest: hash_file(&stage.path().join(EXE))?,
        target,
        parent_pid: std::process::id(),
        version: version.to_string(),
        previous_version: current.to_string(),
        args,
        working_dir: std::env::current_dir()?,
        interactive,
        error: None,
    };
    save_request(stage.path(), &request)?;
    report("Restarting the tool to complete the update");
    handoff(stage, &request)
}

fn lock_target(target: &Path) -> Result<File> {
    let path = target.with_extension("update.lock");
    regular_or_missing(&path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    file.try_lock()
        .map_err(|error| anyhow::anyhow!("Another tool update is in progress: {error}"))?;
    Ok(file)
}

fn atomic_copy(source: &Path, destination: &Path, scratch: &Path) -> Result<()> {
    regular_or_missing(source)?;
    regular_or_missing(destination)?;
    let mut file = File::create_new(scratch)?;
    io::copy(&mut File::open(source)?, &mut file)?;
    file.sync_all()?;
    file.set_permissions(fs::metadata(source)?.permissions())?;
    drop(file);
    let start = Instant::now();
    loop {
        match fs::rename(scratch, destination) {
            Ok(()) => return Ok(()),
            Err(error)
                if cfg!(windows)
                    && (error.kind() == io::ErrorKind::PermissionDenied
                        || matches!(error.raw_os_error(), Some(32 | 33)))
                    && start.elapsed() < Duration::from_secs(5) =>
            {
                thread::sleep(Duration::from_millis(50))
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("Cannot replace {}", destination.display()));
            }
        }
    }
}

fn destinations(request: &Request) -> [PathBuf; 3] {
    let parent = request.target.parent().unwrap();
    [
        request.target.clone(),
        parent.join("LICENSE"),
        parent.join(NOTICE),
    ]
}

fn replace_files(
    request: &Request,
    stage: &Path,
    action: impl FnOnce() -> Result<()>,
) -> Result<()> {
    ensure!(
        hash_file(&request.target)? == request.previous_digest,
        "The installed executable changed during the update"
    );
    ensure!(
        hash_file(&stage.join(EXE))? == request.new_digest,
        "The prepared executable changed during the update"
    );
    let destinations = destinations(request);
    let mut existed = [false; 3];
    for (i, path) in destinations.iter().enumerate() {
        regular_or_missing(path)?;
        if path.exists() {
            fs::copy(path, stage.join(format!("previous-{i}")))?;
            existed[i] = true;
        }
    }
    let mut changed = Vec::new();
    let result = (|| {
        for (i, source) in [EXE, "LICENSE", NOTICE].iter().enumerate() {
            atomic_copy(
                &stage.join(source),
                &destinations[i],
                &stage.join(format!("replace-{i}")),
            )?;
            changed.push(i);
        }
        action()
    })();
    if let Err(error) = result {
        for i in changed.into_iter().rev() {
            let restored = if existed[i] {
                atomic_copy(
                    &stage.join(format!("previous-{i}")),
                    &destinations[i],
                    &stage.join(format!("restore-{i}")),
                )
            } else {
                fs::remove_file(&destinations[i]).map_err(Into::into)
            };
            if let Err(rollback_error) = restored {
                bail!(
                    "Update failed: {error:#}. Restore failed: {rollback_error:#}. The previous files are saved in {}",
                    stage.display()
                );
            }
        }
        return Err(error.context("Tool update failed; previous files were restored"));
    }
    Ok(())
}

fn restart_command(request: &Request, stage: &Path, pid: u32) -> Command {
    let mut command = Command::new(&request.target);
    command
        .arg(FINISH)
        .arg(stage)
        .arg(pid.to_string())
        .arg("--no-self-update")
        .args(&request.args)
        .current_dir(&request.working_dir);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(if request.interactive { 0 } else { 0x0800_0000 });
    }
    command
}

#[cfg(windows)]
fn handoff(stage: TempDir, _: &Request) -> Result<bool> {
    let mut command = Command::new(stage.path().join(EXE));
    hidden(&mut command).arg(APPLY).arg(stage.path());
    let mut child = command
        .spawn()
        .context("Cannot start the tool update process")?;
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            bail!("The update process stopped before it was ready: {status}");
        }
        if stage.path().join("ready").is_file() {
            break;
        }
        if start.elapsed() > Duration::from_secs(10) {
            let _ = child.kill();
            let _ = child.wait();
            bail!("The update process did not become ready");
        }
        thread::sleep(Duration::from_millis(25));
    }
    let _ = stage.keep();
    Ok(true)
}

#[cfg(unix)]
fn handoff(stage: TempDir, request: &Request) -> Result<bool> {
    use std::os::unix::process::CommandExt;
    let _lock = lock_target(&request.target)?;
    replace_files(request, stage.path(), || {
        check_binary(&request.target, &request.version)?;
        log::logger().flush();
        let error = restart_command(request, stage.path(), 0).exec();
        Err(error).context("Cannot restart the updated tool")
    })?;
    unreachable!("A successful exec does not return")
}

#[cfg(windows)]
fn wait_parent(pid: u32) -> Result<()> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, ERROR_INVALID_PARAMETER, GetLastError, WAIT_OBJECT_0},
        System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE, WaitForSingleObject},
    };
    ensure!(
        pid > 0 && pid != std::process::id(),
        "Invalid update parent process"
    );
    // The handle stays valid even if Windows later reuses this process ID.
    let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    if handle.is_null() {
        let error = unsafe { GetLastError() };
        if error == ERROR_INVALID_PARAMETER {
            return Ok(());
        }
        return Err(io::Error::from_raw_os_error(error as i32).into());
    }
    let result = unsafe { WaitForSingleObject(handle, 30_000) };
    unsafe {
        CloseHandle(handle);
    }
    ensure!(
        result == WAIT_OBJECT_0,
        "The previous tool process did not close"
    );
    Ok(())
}

#[cfg(unix)]
fn wait_parent(pid: u32) -> Result<()> {
    ensure!(
        pid > 0 && pid <= i32::MAX as u32 && pid != std::process::id(),
        "Invalid update parent process"
    );
    let start = Instant::now();
    loop {
        // Signal zero checks for the process without sending a signal.
        if unsafe { libc::kill(pid as i32, 0) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(());
            }
            return Err(error.into());
        }
        ensure!(
            start.elapsed() < Duration::from_secs(30),
            "The previous tool process did not close"
        );
        thread::sleep(Duration::from_millis(25));
    }
}

fn apply(stage: &Path) -> Result<()> {
    let mut request = read_request(stage)?;
    ensure!(
        request.version == env!("CARGO_PKG_VERSION"),
        "Wrong update process version"
    );
    ensure!(
        fs::canonicalize(std::env::current_exe()?)? == fs::canonicalize(stage.join(EXE))?,
        "The update process must run from its prepared folder"
    );
    ensure!(
        hash_file(&stage.join(EXE))? == request.new_digest,
        "Prepared executable digest mismatch"
    );
    #[cfg(windows)]
    if request.interactive {
        // Keep the original console alive while the old program exits.
        // The restarted program inherits this console and its input handles.
        ensure!(
            unsafe { windows_sys::Win32::System::Console::AttachConsole(request.parent_pid) } != 0,
            "Cannot keep the program console open: {}",
            io::Error::last_os_error()
        );
    }
    // This handshake must remain compatible with earlier updater versions.
    File::create_new(stage.join("ready"))?.sync_all()?;
    wait_parent(request.parent_pid)?;
    let result = (|| {
        let _lock = lock_target(&request.target)?;
        replace_files(&request, stage, || {
            check_binary(&request.target, &request.version)?;
            restart_command(&request, stage, std::process::id())
                .spawn()
                .context("Cannot restart the updated tool")?;
            Ok(())
        })
    })();
    if let Err(error) = result {
        if hash_file(&request.target).ok().as_deref() == Some(&request.previous_digest)
            && check_binary(&request.target, &request.previous_version).is_ok()
        {
            request.error = Some(format!("{error:#}"));
            save_request(stage, &request)?;
            restart_command(&request, stage, std::process::id())
                .spawn()
                .context("Cannot restart the previous tool")?;
        }
        return Err(error);
    }
    Ok(())
}

pub fn helper(args: &[OsString]) -> Option<Result<()>> {
    if args.get(1).is_none_or(|arg| arg != APPLY) {
        return None;
    }
    Some((|| {
        ensure!(args.len() == 3, "Invalid tool update process arguments");
        apply(Path::new(&args[2]))
    })())
}

fn cleanup(stage: &Path) -> Result<()> {
    let mut allowed: Vec<String> = [EXE, "LICENSE", NOTICE, REQUEST, "release.archive", "ready"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    for prefix in ["previous", "replace", "restore"] {
        allowed.extend((0..3).map(|i| format!("{prefix}-{i}")));
    }
    let files: Vec<_> = fs::read_dir(stage)?.collect::<io::Result<_>>()?;
    for entry in &files {
        ensure!(
            entry.file_type()?.is_file()
                && allowed
                    .iter()
                    .any(|name| entry.file_name() == name.as_str()),
            "Unexpected file in the update folder; cleanup was skipped"
        );
    }
    for entry in files {
        fs::remove_file(entry.path())?;
    }
    fs::remove_dir(stage)?;
    Ok(())
}

pub fn startup_args(mut args: Vec<OsString>) -> Result<Vec<OsString>> {
    if args.get(1).is_none_or(|arg| arg != FINISH) {
        return Ok(args);
    }
    ensure!(args.len() >= 4, "Invalid tool update restart arguments");
    let stage = Path::new(&args[2]);
    let request = read_request(stage)?;
    ensure!(
        fs::canonicalize(std::env::current_exe()?)? == fs::canonicalize(&request.target)?,
        "The restarted program does not match the update target"
    );
    let digest = hash_file(&request.target)?;
    ensure!(
        digest == request.new_digest || digest == request.previous_digest,
        "The restarted executable changed during the update"
    );
    let pid: u32 = args[3]
        .to_str()
        .context("Invalid update process ID")?
        .parse()?;
    if pid != 0 {
        wait_parent(pid)?;
    }
    if let Some(error) = request.error {
        eprintln!("Tool update failed. The previous version was restored: {error}");
    }
    if let Err(error) = cleanup(stage) {
        eprintln!("Tool update finished; temporary files could not be removed: {error:#}");
    }
    args.drain(1..4);
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::net::TcpListener;

    fn release(version: &str, os: &str, arch: &str) -> Release {
        let name = package_name(&Version::parse(version).unwrap(), os, arch).unwrap();
        Release {
            tag_name: format!("v{version}"),
            draft: false,
            prerelease: false,
            assets: vec![Asset {
                browser_download_url: format!(
                    "https://github.com/{REPOSITORY}/releases/download/v{version}/{name}"
                ),
                name,
                size: 3,
                digest: Some(format!("sha256:{}", "a".repeat(64))),
                state: "uploaded".into(),
            }],
        }
    }

    #[test]
    fn picks_each_native_platform_and_never_downgrades() {
        let current = Version::parse("0.5.0").unwrap();
        for (os, arch) in [
            ("windows", "x86_64"),
            ("linux", "x86_64"),
            ("linux", "aarch64"),
            ("macos", "x86_64"),
            ("macos", "aarch64"),
        ] {
            let (version, asset) = select_asset(release("0.6.0", os, arch), &current, os, arch)
                .unwrap()
                .unwrap();
            assert_eq!(version.to_string(), "0.6.0");
            assert_eq!(asset.name, package_name(&version, os, arch).unwrap());
            for version in ["0.4.0", "0.5.0"] {
                assert!(
                    select_asset(release(version, os, arch), &current, os, arch)
                        .unwrap()
                        .is_none()
                );
            }
        }
        assert!(package_name(&current, "windows", "aarch64").is_err());
        assert!(package_name(&current, "linux", "riscv64").is_err());
    }

    #[test]
    fn rejects_preview_ambiguous_untrusted_and_incomplete_releases() {
        let current = Version::parse("0.5.0").unwrap();
        for mutation in 0..9 {
            let mut release = release("0.6.0", "windows", "x86_64");
            match mutation {
                0 => release.prerelease = true,
                1 => release.draft = true,
                2 => release.tag_name = "v0.6.0-rc.1".into(),
                3 => release.assets[0].digest = None,
                4 => release.assets[0].digest = Some("sha256:no".into()),
                5 => release.assets[0].browser_download_url = "https://example.com/tool.zip".into(),
                6 => release.assets.push(release.assets[0].clone()),
                7 => release.assets[0].size = MAX_DOWNLOAD + 1,
                _ => release.assets[0].state = "new".into(),
            }
            assert!(select_asset(release, &current, "windows", "x86_64").is_err());
        }
        assert!(bounded_read(Cursor::new([0; 10]), 9).is_err());
    }

    fn server(body: Vec<u8>, status: u16, advertised: usize) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/file", listener.local_addr().unwrap());
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 8192];
            stream.read(&mut request).unwrap();
            write!(stream, "HTTP/1.1 {status} Test\r\nContent-Length: {advertised}\r\nConnection: close\r\n\r\n").unwrap();
            let _ = stream.write_all(&body);
        });
        (url, handle)
    }

    #[test]
    fn download_checks_http_length_and_digest_before_installation() {
        let client = Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        for (status, advertised, digest_ok, expected_ok) in [
            (200, 3, true, true),
            (200, 4, true, false),
            (200, 3, false, false),
            (503, 3, true, false),
        ] {
            let root = tempfile::tempdir().unwrap();
            let (url, handle) = server(b"abc".to_vec(), status, advertised);
            let asset = Asset {
                name: "tool.zip".into(),
                browser_download_url: url,
                size: 3,
                state: "uploaded".into(),
                digest: Some(format!(
                    "sha256:{}",
                    if digest_ok {
                        format!("{:x}", Sha256::digest(b"abc"))
                    } else {
                        "0".repeat(64)
                    }
                )),
            };
            assert_eq!(
                download(&client, &asset, &root.path().join("archive")).is_ok(),
                expected_ok
            );
            handle.join().unwrap();
        }
    }

    fn archive(root: &Path, zip: bool, files: &[(&str, &[u8])]) -> PathBuf {
        let path = root.join("archive");
        if zip {
            let mut writer = zip::ZipWriter::new(File::create(&path).unwrap());
            for (name, data) in files {
                writer
                    .start_file(*name, zip::write::SimpleFileOptions::default())
                    .unwrap();
                writer.write_all(data).unwrap();
            }
            writer.finish().unwrap();
        } else {
            let encoder = flate2::write::GzEncoder::new(
                File::create(&path).unwrap(),
                flate2::Compression::default(),
            );
            let mut writer = tar::Builder::new(encoder);
            for (name, data) in files {
                let mut header = tar::Header::new_gnu();
                header.set_size(data.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                writer
                    .append_data(&mut header, *name, Cursor::new(data))
                    .unwrap();
            }
            writer.into_inner().unwrap().finish().unwrap();
        }
        path
    }

    #[test]
    fn extracts_only_program_and_licenses_from_zip_and_tar() {
        for zip in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let stage = tempfile::tempdir().unwrap();
            let name = format!("micropython-esp-flasher/{EXE}");
            let path = archive(
                root.path(),
                zip,
                &[
                    (name.as_str(), b"binary"),
                    ("micropython-esp-flasher/LICENSE", b"license"),
                    (
                        "micropython-esp-flasher/THIRD-PARTY-LICENSES.html",
                        b"notice",
                    ),
                    ("micropython-esp-flasher/README.md", b"ignored"),
                ],
            );
            unpack(&path, zip, stage.path()).unwrap();
            assert_eq!(fs::read(stage.path().join(EXE)).unwrap(), b"binary");
            assert_eq!(fs::read_dir(stage.path()).unwrap().count(), 3);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_ne!(
                    fs::metadata(stage.path().join(EXE))
                        .unwrap()
                        .permissions()
                        .mode()
                        & 0o111,
                    0
                );
            }
        }
    }

    #[test]
    fn rejects_missing_duplicate_and_linked_archive_entries() {
        let root = tempfile::tempdir().unwrap();
        let exe = format!("micropython-esp-flasher/{EXE}");
        for zip in [true, false] {
            let stage = tempfile::tempdir().unwrap();
            let path = archive(root.path(), zip, &[(exe.as_str(), b"binary")]);
            assert!(unpack(&path, zip, stage.path()).is_err());
        }
        let stage = tempfile::tempdir().unwrap();
        let path = archive(
            root.path(),
            false,
            &[(exe.as_str(), b"binary"), (exe.as_str(), b"duplicate")],
        );
        assert!(unpack(&path, false, stage.path()).is_err());
        let path = root.path().join("link.tar.gz");
        let mut writer = tar::Builder::new(flate2::write::GzEncoder::new(
            File::create(&path).unwrap(),
            flate2::Compression::default(),
        ));
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::Symlink);
        header.set_size(0);
        header.set_mode(0o777);
        header.set_link_name("../../precious").unwrap();
        header.set_cksum();
        writer.append_data(&mut header, exe, io::empty()).unwrap();
        writer.into_inner().unwrap().finish().unwrap();
        assert!(unpack(&path, false, tempfile::tempdir().unwrap().path()).is_err());
    }

    fn prepared(root: &Path) -> (TempDir, Request) {
        let target = root.join("installed-program");
        fs::write(&target, b"old-program").unwrap();
        fs::write(root.join("LICENSE"), b"old-license").unwrap();
        let stage = Builder::new().prefix(PREFIX).tempdir_in(root).unwrap();
        fs::write(stage.path().join(EXE), b"new-program").unwrap();
        fs::write(stage.path().join("LICENSE"), b"new-license").unwrap();
        fs::write(stage.path().join(NOTICE), b"new-notice").unwrap();
        let request = Request {
            target: fs::canonicalize(&target).unwrap(),
            parent_pid: 1234,
            version: "0.6.0".into(),
            previous_version: "0.5.0".into(),
            previous_digest: hash_file(&target).unwrap(),
            new_digest: hash_file(&stage.path().join(EXE)).unwrap(),
            args: vec![],
            working_dir: root.to_owned(),
            interactive: false,
            error: None,
        };
        save_request(stage.path(), &request).unwrap();
        (stage, request)
    }

    #[test]
    fn install_and_rollback_leave_firmware_logs_and_other_files_unchanged() {
        for success in [true, false] {
            let root = tempfile::tempdir().unwrap();
            fs::create_dir(root.path().join("firmware")).unwrap();
            fs::write(root.path().join("firmware/board.bin"), b"keep-firmware").unwrap();
            fs::write(root.path().join("personal-file"), b"keep-personal").unwrap();
            let (stage, request) = prepared(root.path());
            assert_eq!(
                replace_files(&request, stage.path(), || {
                    if success {
                        Ok(())
                    } else {
                        bail!("New program failed its launch check")
                    }
                })
                .is_ok(),
                success
            );
            assert_eq!(
                fs::read(&request.target).unwrap(),
                if success {
                    b"new-program"
                } else {
                    b"old-program"
                }
            );
            assert_eq!(
                fs::read(root.path().join("LICENSE")).unwrap(),
                if success {
                    b"new-license"
                } else {
                    b"old-license"
                }
            );
            assert_eq!(root.path().join(NOTICE).exists(), success);
            assert_eq!(
                fs::read(root.path().join("firmware/board.bin")).unwrap(),
                b"keep-firmware"
            );
            assert_eq!(
                fs::read(root.path().join("personal-file")).unwrap(),
                b"keep-personal"
            );
        }
    }

    #[test]
    fn refuses_a_stale_install_and_does_not_clean_unknown_files() {
        let root = tempfile::tempdir().unwrap();
        let (stage, request) = prepared(root.path());
        fs::write(&request.target, b"another-update").unwrap();
        assert!(replace_files(&request, stage.path(), || Ok(())).is_err());
        assert_eq!(fs::read(&request.target).unwrap(), b"another-update");
        fs::write(stage.path().join("personal-file"), b"keep").unwrap();
        assert!(cleanup(stage.path()).is_err());
        assert!(stage.path().join(EXE).exists());
        assert!(stage.path().join("personal-file").exists());
        assert!(read_request(root.path()).is_err());
    }

    #[test]
    fn only_one_installer_can_hold_the_update_lock() {
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("program");
        let lock = lock_target(&target).unwrap();
        assert!(lock_target(&target).is_err());
        drop(lock);
        assert!(lock_target(&target).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn does_not_follow_license_destination_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let (stage, request) = prepared(root.path());
        fs::write(root.path().join("personal-file"), b"keep").unwrap();
        fs::remove_file(root.path().join("LICENSE")).unwrap();
        std::os::unix::fs::symlink(
            root.path().join("personal-file"),
            root.path().join("LICENSE"),
        )
        .unwrap();
        assert!(replace_files(&request, stage.path(), || Ok(())).is_err());
        assert_eq!(fs::read(&request.target).unwrap(), b"old-program");
        assert_eq!(
            fs::read(root.path().join("personal-file")).unwrap(),
            b"keep"
        );
    }
}
