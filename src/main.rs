mod catalog;
mod device;
mod image;
mod logging;
mod plan;
mod repl;
mod self_update;
mod ui;

use anyhow::{Context, Result, bail, ensure};
use catalog::{Builds, Catalog};
use clap::{Parser, Subcommand};
use device::{Connected, Hardware, PortInfo};
use plan::Change;
use repl::Running;
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
use ui::{Item, Progress, Ui};

#[derive(Debug, Parser)]
#[command(version, about = "Install and update MicroPython on ESP32 boards")]
struct Args {
    /// Use these serial ports instead of automatic detection
    #[arg(long, short, global = true, value_delimiter = ',')]
    port: Vec<String>,
    /// Store firmware and logs in this folder (default: next to the executable)
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    /// Use cached firmware without network requests
    #[arg(long, global = true)]
    offline: bool,
    /// Accept normal flash/skip actions without a countdown (does not permit an implicit erase)
    #[arg(long, short = 'y', global = true)]
    yes: bool,
    /// Close without waiting for a key
    #[arg(long, global = true)]
    no_pause: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Read connected boards without writing firmware; print JSON
    Probe,
    /// Show the selected firmware and action without writing firmware
    Plan,
    /// Save the full flash of one explicitly selected board
    Backup {
        #[arg(long, short)]
        output: PathBuf,
    },
    /// Install or update MicroPython (also the default action)
    Flash {
        /// Flash even when the selected version is already installed
        #[arg(long)]
        force: bool,
        /// Erase the whole chip before flashing
        #[arg(long)]
        erase: bool,
        /// Select a build variant; use 'base' for the base build
        #[arg(long)]
        variant: Option<String>,
    },
}

#[derive(Debug, Serialize)]
struct Target {
    port: PortInfo,
    hardware: Hardware,
    running: Option<Running>,
}

#[derive(Clone, Copy, Default)]
struct FlashOptions<'a> {
    force: bool,
    erase: bool,
    variant: Option<&'a str>,
}

fn inspect(port: &PortInfo) -> Result<Target> {
    ensure!(
        !port.firmware_usb,
        "{} is a firmware-only USB port. Hold BOOT, tap RESET, release BOOT and run again.",
        port.name
    );
    let running = repl::probe(&port.name, port.native())?;
    let mut connected = match Connected::open(port, None) {
        Ok(connected) => connected,
        Err(error) if running.is_some() => bail!(
            "MicroPython answered on {}, but the flash connection failed: {error:#}",
            port.name
        ),
        Err(error) => return Err(error),
    };
    let hardware = connected.hardware(running.as_ref())?;
    Ok(Target {
        port: port.clone(),
        hardware,
        running,
    })
}

fn select_ports(args: &Args) -> Result<(Vec<PortInfo>, Vec<PortInfo>)> {
    let ports = device::ports()?;
    if !args.port.is_empty() {
        let mut selected = Vec::new();
        for name in &args.port {
            let port = ports
                .iter()
                .find(|port| port.name.eq_ignore_ascii_case(name))
                .with_context(|| format!("USB serial port {name} was not found"))?;
            if !selected.iter().any(|p: &PortInfo| p.name == port.name) {
                selected.push(port.clone());
            }
        }
        return Ok((selected, Vec::new()));
    }
    let known = ports.iter().filter(|port| port.known).cloned().collect();
    let unknown = ports
        .into_iter()
        .filter(|port| !port.known && !port.firmware_usb)
        .collect();
    Ok((known, unknown))
}

fn read_targets(ports: &[PortInfo], ui: Option<&Ui>, explicit: bool) -> (Vec<Target>, usize) {
    let mut targets = Vec::new();
    let mut seen = HashSet::new();
    let mut failures = 0;
    for port in ports {
        match inspect(port) {
            Ok(target) => {
                if let Some(mac) = &target.hardware.mac
                    && !seen.insert(mac.clone())
                {
                    if let Some(ui) = ui {
                        ui.step(
                            "skip",
                            format!("{} is another port of an already detected board", port.name),
                        );
                    }
                    continue;
                }
                targets.push(target);
            }
            Err(error) => {
                if !explicit && error.downcast_ref::<device::NoChip>().is_some() {
                    log::info!("{} skipped: {error:#}", port.name);
                    if let Some(ui) = ui {
                        ui.step("skip", format!("{}: no supported ESP32 answer", port.name));
                    }
                    continue;
                }
                failures += 1;
                log::error!("{}: {error:#}", port.name);
                if let Some(ui) = ui {
                    ui.error(&format!("{}: {error:#}", port.name));
                } else {
                    eprintln!("{}: {error:#}", port.name);
                }
            }
        }
    }
    (targets, failures)
}

fn show_target(target: &Target, ui: &Ui) {
    ui.section(&target.port.name);
    log::info!(
        "USB ID       {:04x}:{:04x}",
        target.port.vid,
        target.port.pid
    );
    if let Some(serial) = &target.port.serial {
        log::info!("serial       {serial}");
    }
    ui.step(
        "repl",
        target
            .running
            .as_ref()
            .map_or("no MicroPython answer".into(), |r| {
                format!("MicroPython {}   {}", r.version, r.machine)
            }),
    );
    ui.step(
        "chip",
        format!(
            "{}   {}MB flash   {}MB PSRAM",
            target.hardware.chip,
            target.hardware.flash_size / 1024 / 1024,
            target.hardware.psram_mb
        ),
    );
    if let Some(mac) = &target.hardware.mac {
        ui.step("MAC", mac);
    }
    if let Some(running) = &target.running {
        if !running.build.is_empty() {
            ui.step("build", &running.build);
        }
        if let Some(filesystem) = running.filesystem {
            ui.step("filesystem", format!("0x{filesystem:x}"));
        }
    }
}

fn variant_name(variant: &str) -> &str {
    if variant.is_empty() { "base" } else { variant }
}

fn choose_variant(ui: &Ui, builds: &Builds, default: &str) -> Result<Option<String>> {
    let variants: Vec<_> = builds.keys().cloned().collect();
    if variants.len() == 1 {
        return Ok(variants.first().cloned());
    }
    let items: Vec<_> = variants
        .iter()
        .enumerate()
        .map(|(i, variant)| {
            Item::new(
                char::from_digit((i + 1) as u32, 10).unwrap_or('\0'),
                variant_name(variant),
                builds[variant].version.to_string(),
            )
        })
        .collect();
    let default = variants.iter().position(|v| v == default).unwrap_or(0);
    Ok(ui
        .choose("Choose a firmware build", &items, default, None)?
        .map(|i| variants[i].clone()))
}

fn erase_confirm(ui: &Ui) -> Result<bool> {
    Ok(ui.choose(
        "Erase the whole chip? All files will be deleted.",
        &[
            Item::new('c', "Cancel", "Keep board files"),
            Item::new('e', "Erase and install", "Deletes all board files").danger(),
        ],
        0,
        Some(0),
    )? == Some(1))
}

fn wait_port(previous: &PortInfo) -> Result<PortInfo> {
    let start = Instant::now();
    thread::sleep(Duration::from_millis(700));
    loop {
        if let Ok(ports) = device::ports()
            && let Some(port) = ports.into_iter().find(|port| {
                port.vid == previous.vid
                    && port.pid == previous.pid
                    && (previous
                        .serial
                        .as_ref()
                        .map_or(port.name == previous.name, |serial| {
                            port.serial.as_ref() == Some(serial)
                        }))
            })
        {
            return Ok(port);
        }
        ensure!(
            start.elapsed() < Duration::from_secs(20),
            "The board did not reconnect after flashing"
        );
        thread::sleep(Duration::from_millis(200));
    }
}

fn flash(target: &Target, path: &Path, erase: bool, ui: &Ui) -> Result<()> {
    let image = image::Image::read(path)?;
    ensure!(
        image.chip_id == target.hardware.chip.id(),
        "Firmware is for another chip"
    );
    let mut last = None;
    for baud in [2_000_000, 921_600, 460_800, 115_200] {
        ui.step("connect", format!("{baud} baud"));
        let result = (|| -> Result<()> {
            let mut connected = Connected::open(&target.port, Some(baud))?;
            let actual = connected.hardware(target.running.as_ref())?;
            ensure!(
                actual.chip == target.hardware.chip && actual.mac == target.hardware.mac,
                "The board on this port changed; no firmware was written"
            );
            if erase {
                ui.warning("Erasing the whole chip");
            }
            connected.write(&actual, path, erase, &mut Progress::new(ui))?;
            Ok(())
        })();
        match result {
            Ok(()) => return Ok(()),
            Err(error) => {
                ui.warning(&format!("Attempt at {baud} baud failed: {error:#}"));
                last = Some(error);
            }
        }
    }
    Err(last.unwrap()).context("Flashing failed at every baud rate")
}

fn update(
    target: &Target,
    builds: &Builds,
    online: bool,
    catalog: &Catalog,
    args: &Args,
    options: FlashOptions<'_>,
    ui: &Ui,
) -> Result<&'static str> {
    let board = &target.hardware.board;
    let mut variant = if let Some(variant) = options.variant {
        let variant = if variant.eq_ignore_ascii_case("base") {
            ""
        } else {
            variant
        };
        ensure!(
            builds.contains_key(variant),
            "Variant '{variant}' is not available for {board}"
        );
        variant.to_owned()
    } else {
        match catalog::select_variant(builds, &target.hardware.names(), online) {
            Ok(variant) => variant,
            Err(error) => {
                ui.warning(&error.to_string());
                if args.yes {
                    return Err(error);
                }
                let Some(variant) = choose_variant(ui, builds, "")? else {
                    return Ok("skipped");
                };
                variant
            }
        }
    };
    let mut automatic = true;
    let (build, change, erase) = loop {
        let build = &builds[&variant];
        let change = plan::classify(board, target.running.as_ref(), build);
        let from = target
            .running
            .as_ref()
            .map_or("no MicroPython".into(), |r| {
                plan::running_variant(board, r)
                    .filter(|running| *running != variant)
                    .map_or(r.version.clone(), |v| {
                        format!("{} {}", r.version, variant_name(v))
                    })
            });
        let selected_build = if variant.is_empty() {
            board.clone()
        } else {
            format!("{board}-{variant}")
        };
        ui.card(
            "Firmware plan",
            &[
                (
                    "MicroPython",
                    &format!("{from} → {}", build.version),
                    crossterm::style::Color::White,
                ),
                ("Build", &selected_build, crossterm::style::Color::White),
                (
                    "Status",
                    change.label(),
                    match change {
                        Change::UpToDate => crossterm::style::Color::Green,
                        Change::WrongBuild | Change::Newer => crossterm::style::Color::Yellow,
                        _ => crossterm::style::Color::Cyan,
                    },
                ),
                (
                    "Firmware",
                    if catalog.cache.join(&build.name).is_file() {
                        "cached"
                    } else {
                        "will be downloaded"
                    },
                    crossterm::style::Color::Grey,
                ),
            ],
        );
        let needed = change.needed() || options.force || options.erase || options.variant.is_some();
        if matches!(args.command, Some(Command::Plan)) {
            return Ok(if change.needed() {
                "would flash"
            } else {
                "would skip"
            });
        }
        let action = if options.erase {
            "erase and install".into()
        } else if needed {
            format!("install {}", build.version)
        } else {
            "skip".into()
        };
        let menu = if args.yes {
            false
        } else if automatic {
            ui.countdown(&action)?
        } else {
            true
        };
        if !menu {
            if !needed {
                ui.step("skip", "nothing written");
                return Ok("skipped");
            }
            if options.erase && !args.yes && !erase_confirm(ui)? {
                return Ok("skipped");
            }
            break (build.clone(), change, options.erase);
        }
        automatic = false;
        let mut items = vec![
            Item::new('f', format!("Install {}", build.version), "Write firmware"),
            Item::new('e', "Erase and install", "Deletes all board files").danger(),
        ];
        if builds.len() > 1 {
            items.push(Item::new('v', "Choose build", "Select a firmware variant"));
        }
        items.push(Item::new('s', "Skip", "Keep the board as it is"));
        let skip = items.len() - 1;
        let choice = ui
            .choose(
                "Choose an action",
                &items,
                if needed { 0 } else { skip },
                Some(skip),
            )?
            .unwrap_or(skip);
        match items[choice].key {
            's' => return Ok("skipped"),
            'v' => {
                if let Some(selected) = choose_variant(ui, builds, &variant)? {
                    variant = selected;
                }
            }
            'e' => {
                if erase_confirm(ui)? {
                    break (build.clone(), change, true);
                }
            }
            _ => break (build.clone(), change, false),
        }
    };
    ui.step("firmware", &build.name);
    let path = catalog.firmware(board, &build)?;
    let image = image::Image::read(&path)?;
    let mut erase = erase;
    if !erase
        && target
            .running
            .as_ref()
            .is_some_and(|running| plan::files_move(board, running, &variant, image.filesystem))
    {
        if args.yes {
            bail!(
                "The new build may lose board files. Run interactively, or explicitly select flash --erase."
            );
        }
        if !erase_confirm(ui)? {
            return Ok("skipped");
        }
        erase = true;
    }
    flash(target, &path, erase, ui)?;
    ui.step("reboot", "waiting for the board");
    let port = wait_port(&target.port)?;
    let running = repl::probe(&port.name, port.native())?
        .context("Firmware was written, but MicroPython did not answer; power-cycle the board")?;
    ensure!(
        catalog::Version::parse(&running.version) == Some(build.version),
        "The board reports version {}, expected {}",
        running.version,
        build.version
    );
    if !running.build.is_empty() {
        ensure!(
            plan::running_variant(board, &running) == Some(variant.as_str()),
            "The board reports build {}, expected {board}-{}",
            running.build,
            variant_name(&variant)
        );
    }
    if port.name != target.port.name {
        ui.step("port", format!("{} (reconnected)", port.name));
    }
    ui.step(
        "ready",
        format!("MicroPython {} is running", running.version),
    );
    Ok(match change {
        Change::Install => "installed",
        Change::WrongBuild => "build fixed",
        Change::Update => "updated",
        _ => "flashed again",
    })
}

fn run(args: &Args, root: &Path, ui: &Ui) -> Result<()> {
    let (ports, mut unknown) = select_ports(args)?;
    if matches!(args.command, Some(Command::Probe)) {
        ensure!(!ports.is_empty(), "No supported USB serial port was found");
        let (targets, failed) = read_targets(&ports, None, !args.port.is_empty());
        println!("{}", serde_json::to_string_pretty(&targets)?);
        ensure!(failed == 0, "Could not read {failed} port(s)");
        ensure!(!targets.is_empty(), "No ESP32 chip was detected");
        return Ok(());
    }
    if let Some(Command::Backup { output }) = &args.command {
        ensure!(
            args.port.len() == 1 && ports.len() == 1,
            "For a backup, select exactly one port with --port"
        );
        let target = inspect(&ports[0])?;
        ui.step(
            "backup",
            format!("{} → {}", target.port.name, output.display()),
        );
        Connected::open(&target.port, Some(921_600))?.backup(&target.hardware, output)?;
        ui.step("backup", "complete");
        return Ok(());
    }
    ensure!(
        ui.interactive || args.yes || matches!(args.command, Some(Command::Plan)),
        "Use a terminal, or specify --yes. Use probe or plan to inspect boards without writing firmware."
    );
    if ports.is_empty() && unknown.is_empty() {
        let firmware_usb = device::ports()?.iter().any(|port| port.firmware_usb);
        if firmware_usb {
            bail!(
                "The board exposes only its firmware USB port. Hold BOOT, tap RESET, release BOOT and run again."
            );
        }
        bail!("No ESP32 adapter was found. Connect a board and run again.");
    }
    let catalog = Catalog::new(root, args.offline)?;
    let options = match &args.command {
        Some(Command::Flash {
            force,
            erase,
            variant,
        }) => FlashOptions {
            force: *force,
            erase: *erase,
            variant: variant.as_deref(),
        },
        _ => FlashOptions::default(),
    };
    let mut catalogs = HashMap::new();
    ui.step("scan", "reading USB serial ports");
    let (targets, mut failures) = read_targets(&ports, Some(ui), !args.port.is_empty());
    let mut seen: HashSet<String> = targets
        .iter()
        .filter_map(|target| target.hardware.mac.clone())
        .collect();
    let mut process = |target: &Target| -> Result<&'static str> {
        show_target(target, ui);
        let board = &target.hardware.board;
        if !catalogs.contains_key(board) {
            ui.step("catalog", "asking micropython.org");
            let result = catalog.builds(board)?;
            if !result.1 {
                ui.warning("Offline: using cached firmware; newer releases cannot be checked");
            }
            catalogs.insert(board.clone(), result);
        }
        let (builds, online) = &catalogs[board];
        update(target, builds, *online, &catalog, args, options, ui)
    };
    let mut outcomes = Vec::new();
    for target in &targets {
        match process(target) {
            Ok(outcome) => {
                outcomes.push(outcome);
                ui.result(outcome);
            }
            Err(error) => {
                failures += 1;
                ui.error(&format!("{}: {error:#}", target.port.name));
            }
        }
    }
    while !unknown.is_empty()
        && ui.interactive
        && !args.yes
        && !matches!(args.command, Some(Command::Plan))
    {
        let mut items = vec![Item::new('c', "close", "")];
        items.extend(unknown.iter().enumerate().map(|(i, port)| {
            Item::new(
                char::from_digit((i + 1) as u32, 10).unwrap_or('\0'),
                &port.name,
                format!("unknown adapter {:04x}:{:04x}", port.vid, port.pid),
            )
        }));
        let choice = ui
            .choose("Try a port that was not probed?", &items, 0, Some(0))?
            .unwrap_or(0);
        if choice == 0 {
            break;
        }
        let port = unknown.remove(choice - 1);
        match inspect(&port) {
            Ok(target) => {
                if let Some(mac) = &target.hardware.mac
                    && !seen.insert(mac.clone())
                {
                    ui.step("skip", "this board was already processed");
                    continue;
                }
                match process(&target) {
                    Ok(outcome) => {
                        outcomes.push(outcome);
                        ui.result(outcome);
                    }
                    Err(error) => {
                        failures += 1;
                        ui.error(&format!("{}: {error:#}", port.name));
                    }
                }
            }
            Err(error) => ui.warning(&format!("{}: {error:#}", port.name)),
        }
    }
    let skipped = outcomes
        .iter()
        .filter(|outcome| matches!(**outcome, "skipped" | "would skip"))
        .count();
    ui.summary(
        outcomes.len() - skipped,
        skipped,
        failures,
        matches!(args.command, Some(Command::Plan)),
    );
    ensure!(
        failures == 0,
        "{failures} board operation(s) failed; see the log"
    );
    if targets.is_empty() && !ui.interactive {
        bail!("No ESP32 chip was detected on the selected ports");
    }
    Ok(())
}

fn main() {
    let raw: Vec<_> = std::env::args_os().collect();
    if let Some(result) = self_update::helper(&raw) {
        if let Err(error) = result {
            eprintln!("Tool update failed: {error:#}");
            std::process::exit(1);
        }
        return;
    }
    let (raw, updated) = match self_update::startup_args(raw) {
        Ok(raw) => raw,
        Err(error) => {
            eprintln!("Tool update restart failed: {error:#}");
            std::process::exit(1);
        }
    };
    let args = Args::parse_from(&raw);
    let ui = Ui::new();
    let root = args.data_dir.clone().unwrap_or_else(|| {
        std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(Path::to_owned))
            .unwrap_or_else(|| PathBuf::from("."))
    });
    let log_path = logging::start(&root);
    if !matches!(args.command, Some(Command::Probe)) {
        ui.title();
    }
    if ui.interactive && args.command.is_none() && !args.offline && !updated {
        let result = (|| {
            let restart_args = raw
                .iter()
                .skip(1)
                .map(|arg| {
                    arg.to_str()
                        .map(str::to_owned)
                        .context("Tool update cannot preserve a non-UTF-8 argument")
                })
                .collect::<Result<_>>()?;
            self_update::update(restart_args, ui.interactive, |text| ui.step("tool", text))
        })();
        match result {
            Ok(true) => {
                log::logger().flush();
                std::process::exit(0);
            }
            Ok(false) => (),
            Err(error) => ui.warning(&format!(
                "Tool update unavailable; using this version: {error:#}"
            )),
        }
    }
    let result = run(&args, &root, &ui);
    if let Err(error) = &result {
        if matches!(args.command, Some(Command::Probe)) {
            eprintln!("{error:#}");
        } else {
            ui.error(&format!("{error:#}"));
        }
    }
    if !matches!(args.command, Some(Command::Probe)) {
        if let Some(path) = log_path {
            ui.line(
                &format!("log: {}", path.display()),
                crossterm::style::Color::DarkGrey,
            );
        }
        if !args.no_pause {
            let _ = ui.pause();
        }
    }
    log::info!(
        "Finished: {}",
        if result.is_ok() { "success" } else { "failure" }
    );
    log::logger().flush();
    if result.is_err() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_requires_explicit_force_and_erase() {
        let args = Args::try_parse_from(["flasher", "--yes"]).unwrap();
        assert!(args.command.is_none());
        let args = Args::try_parse_from([
            "flasher",
            "--port",
            "COM5,COM8",
            "flash",
            "--force",
            "--variant",
            "SPIRAM_OCT",
        ])
        .unwrap();
        assert_eq!(args.port, ["COM5", "COM8"]);
        assert!(matches!(
            args.command,
            Some(Command::Flash {
                force: true,
                erase: false,
                ..
            })
        ));
        assert!(Args::try_parse_from(["flasher", "--erase"]).is_err());
    }

    const MANIFEST: &str = r#"import os
try:
    import hashlib
except ImportError:
    import uhashlib as hashlib
import ubinascii
def snapshot(path):
    for name in sorted(os.listdir(path)):
        p = path.rstrip('/') + '/' + name
        if os.stat(p)[0] & 0x4000:
            snapshot(p)
        else:
            h = hashlib.sha256()
            with open(p, 'rb') as f:
                while True:
                    b = f.read(1024)
                    if not b:
                        break
                    h.update(b)
            print(p + ':' + ubinascii.hexlify(h.digest()).decode())
snapshot('/')
"#;

    fn session(port: &PortInfo) -> Result<repl::Session> {
        let mut session = repl::Session::open(&port.name, port.native())?;
        ensure!(session.connect()?, "The test board must run MicroPython");
        Ok(session)
    }

    #[test]
    #[ignore = "Needs MPFLASH_HARDWARE_TEST=1 and MPFLASH_TEST_PORT; backs up and reflashes a real board"]
    fn hardware_reflash_preserves_all_files() -> Result<()> {
        ensure!(
            std::env::var("MPFLASH_HARDWARE_TEST").as_deref() == Ok("1"),
            "Set MPFLASH_HARDWARE_TEST=1 to permit a real flash"
        );
        let name = std::env::var("MPFLASH_TEST_PORT")
            .context("Set MPFLASH_TEST_PORT to the test board's port")?;
        let root = PathBuf::from(
            std::env::var("MPFLASH_DATA_DIR").unwrap_or_else(|_| env!("CARGO_MANIFEST_DIR").into()),
        );
        let port = device::ports()?
            .into_iter()
            .find(|port| port.name == name)
            .context("Test port not found")?;
        let target = inspect(&port)?;
        let running = target
            .running
            .as_ref()
            .context("Test board must already run MicroPython")?;
        let catalog = Catalog::new(&root, true)?;
        let (builds, _) = catalog.builds(&target.hardware.board)?;
        let variant = catalog::select_variant(&builds, &target.hardware.names(), false)?;
        let image = image::Image::read(&catalog.cache.join(&builds[&variant].name))?;
        ensure!(
            !plan::files_move(&target.hardware.board, running, &variant, image.filesystem),
            "Test firmware must preserve the filesystem"
        );
        ensure!(
            catalog::Version::parse(&running.version) == Some(builds[&variant].version),
            "Hardware smoke test only reflashes the current stable version"
        );
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let backup = root
            .join("backups")
            .join(format!("rust-{name}-{stamp}.bin"));
        Connected::open(&port, Some(921_600))?.backup(&target.hardware, &backup)?;
        println!("Full flash backup: {}", backup.display());
        thread::sleep(Duration::from_millis(700));
        let marker = format!("/.mpflash-rust-smoke-{}-{stamp}", std::process::id());
        let marker_json = serde_json::to_string(&marker)?;
        let baseline = {
            let mut session = session(&port)?;
            let baseline = session.execute(MANIFEST)?;
            session.execute(&format!("import os\np={marker_json}\nassert p[1:] not in os.listdir('/')\nwith open(p, 'wb') as f:\n    f.write(b'Rust flash preserves files\\x00\\xff')\n"))?;
            baseline
        };
        let result = (|| -> Result<()> {
            let before = session(&port)?.execute(MANIFEST)?;
            let args = Args::try_parse_from([
                "flasher",
                "--yes",
                "--offline",
                "--no-pause",
                "flash",
                "--force",
            ])?;
            let ui = Ui { interactive: false };
            update(
                &target,
                &builds,
                false,
                &catalog,
                &args,
                FlashOptions {
                    force: true,
                    ..Default::default()
                },
                &ui,
            )?;
            let after = session(&port)?.execute(MANIFEST)?;
            ensure!(
                before == after,
                "Board file hashes changed during the flash"
            );
            println!(
                "Version/build verified; all {} file hashes match",
                after.lines().count()
            );
            Ok(())
        })();
        let cleanup = (|| -> Result<()> {
            let mut session = session(&port)?;
            session.execute(&format!("import os\nos.remove({marker_json})\n"))?;
            let after = session.execute(MANIFEST)?;
            ensure!(after == baseline, "Board files differ after test cleanup");
            Ok(())
        })();
        result?;
        cleanup?;
        Ok(())
    }
}
