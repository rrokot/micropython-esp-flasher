mod catalog;
mod device;
mod image;
mod logging;
mod plan;
mod repl;
mod self_update;
mod ui;

use anyhow::{Context, Result, bail, ensure};
use catalog::{Build, Builds, Catalog};
use clap::{Parser, Subcommand};
use device::{Connected, Hardware, PortInfo};
use plan::Change;
use repl::Running;
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    ops::ControlFlow,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant},
};
use ui::{Item, Progress, Tone, Ui};

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

#[derive(Clone, Debug, Serialize)]
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

/// A board with the firmware build selected for it.
struct Job {
    target: Target,
    builds: Builds,
    online: bool,
    variant: String,
}

impl Job {
    fn board(&self) -> &str {
        &self.target.hardware.board
    }
    fn port(&self) -> &str {
        &self.target.port.name
    }
    fn build(&self) -> &Build {
        &self.builds[&self.variant]
    }
    fn change(&self) -> Change {
        plan::classify(self.board(), self.target.running.as_ref(), self.build())
    }
    fn needed(&self, options: FlashOptions<'_>) -> bool {
        self.change().needed() || options.force || options.erase || options.variant.is_some()
    }
    fn default_action(&self, options: FlashOptions<'_>) -> Action {
        if self.needed(options) {
            Action::Flash {
                erase: options.erase,
            }
        } else {
            Action::Skip
        }
    }
}

#[derive(Clone, Copy)]
enum Action {
    Skip,
    Flash { erase: bool },
}

#[derive(Clone, Copy)]
enum Outcome {
    Installed,
    Updated,
    BuildFixed,
    Reflashed,
    Skipped,
    WouldFlash,
    WouldSkip,
}

impl Outcome {
    fn label(self) -> &'static str {
        match self {
            Self::Installed => "installed",
            Self::Updated => "updated",
            Self::BuildFixed => "build fixed",
            Self::Reflashed => "flashed again",
            Self::Skipped => "skipped",
            Self::WouldFlash => "would flash",
            Self::WouldSkip => "would skip",
        }
    }
    fn tone(self) -> Tone {
        match self {
            Self::Skipped | Self::WouldSkip => Tone::Muted,
            Self::WouldFlash => Tone::Active,
            _ => Tone::Good,
        }
    }
}

/// The user closed the program while it waited for a board.
#[derive(Debug)]
struct Closed;
impl std::fmt::Display for Closed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Closed while waiting for a board")
    }
}
impl std::error::Error for Closed {}

/// Board errors were already shown next to their boards.
#[derive(Debug)]
struct Shown(usize);
impl std::fmt::Display for Shown {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} board operation(s) failed", self.0)
    }
}
impl std::error::Error for Shown {}

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

/// Splits detected ports into known ESP32 adapters and other adapters.
fn split_ports(ports: Vec<PortInfo>) -> (Vec<PortInfo>, Vec<PortInfo>) {
    let known = ports.iter().filter(|port| port.known).cloned().collect();
    let unknown = ports
        .into_iter()
        .filter(|port| !port.known && !port.firmware_usb)
        .collect();
    (known, unknown)
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
    Ok(split_ports(ports))
}

fn missing_board(ports: &[PortInfo]) -> String {
    ports
        .iter()
        .find(|port| port.firmware_usb)
        .map_or("Connect an ESP32 board".into(), |port| {
            format!(
                "{} is the firmware USB port: hold BOOT, tap RESET, release BOOT",
                port.name
            )
        })
}

fn wait_board(ui: &Ui) -> Result<(Vec<PortInfo>, Vec<PortInfo>)> {
    let found = ui
        .wait(|| {
            let ports = device::ports()?;
            let (known, unknown) = split_ports(ports.clone());
            Ok(if known.is_empty() && unknown.is_empty() {
                ControlFlow::Continue(missing_board(&ports))
            } else {
                ControlFlow::Break((known, unknown))
            })
        })?
        .ok_or(Closed)?;
    // A new USB serial port can appear before its driver accepts connections.
    thread::sleep(Duration::from_millis(500));
    Ok(found)
}

fn read_targets(ports: &[PortInfo], ui: Option<&Ui>, explicit: bool) -> (Vec<Target>, Vec<String>) {
    let mut targets = Vec::new();
    let mut seen = HashSet::new();
    let mut failed = Vec::new();
    for port in ports {
        match inspect(port) {
            Ok(target) => {
                if let Some(mac) = &target.hardware.mac
                    && !seen.insert(mac.clone())
                {
                    if let Some(ui) = ui {
                        ui.field(
                            "skip",
                            format!("{} is another port of an already detected board", port.name),
                            Tone::Muted,
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
                        ui.field(
                            "skip",
                            format!("{}: no supported ESP32 answer", port.name),
                            Tone::Muted,
                        );
                    }
                    continue;
                }
                failed.push(port.name.clone());
                log::error!("{}: {error:#}", port.name);
                if let Some(ui) = ui {
                    ui.error(&format!("{}: {error:#}", port.name));
                } else {
                    eprintln!("{}: {error:#}", port.name);
                }
            }
        }
    }
    (targets, failed)
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
    let hardware = &target.hardware;
    let psram = if hardware.psram_mb > 0 {
        format!("{} MB PSRAM", hardware.psram_mb)
    } else if hardware.psram {
        "PSRAM".into()
    } else {
        "no PSRAM".into()
    };
    ui.field(
        "chip",
        format!(
            "{} · {} MB flash · {psram}",
            hardware.chip,
            hardware.flash_size / 1024 / 1024
        ),
        Tone::Normal,
    );
    if let Some(mac) = &hardware.mac {
        ui.field("mac", mac, Tone::Normal);
    }
    match &target.running {
        Some(running) => {
            ui.field(
                "installed",
                format!(
                    "MicroPython {} · {}",
                    running.version,
                    if running.build.is_empty() {
                        &running.machine
                    } else {
                        &running.build
                    }
                ),
                Tone::Normal,
            );
            if let Some(filesystem) = running.filesystem {
                log::info!("filesystem   0x{filesystem:x}");
            }
        }
        None => ui.field("installed", "no MicroPython answer", Tone::Muted),
    }
}

fn variant_name(variant: &str) -> &str {
    if variant.is_empty() { "base" } else { variant }
}

fn build_name(board: &str, variant: &str) -> String {
    if variant.is_empty() {
        board.to_owned()
    } else {
        format!("{board}-{variant}")
    }
}

fn show_plan(job: &Job, catalog: &Catalog, ui: &Ui) {
    let build = job.build();
    let name = build_name(job.board(), &job.variant);
    if job.online {
        ui.field(
            "firmware",
            format!(
                "{} · {name} · {}",
                build.version,
                if catalog.cache.join(&build.name).is_file() {
                    "cached"
                } else {
                    "will be downloaded"
                }
            ),
            Tone::Normal,
        );
    } else {
        ui.field(
            "firmware",
            format!(
                "{} · {name} · offline, newer releases not checked",
                build.version
            ),
            Tone::Warn,
        );
    }
    let change = job.change();
    ui.field(
        "status",
        change.label(),
        match change {
            Change::UpToDate => Tone::Good,
            Change::WrongBuild | Change::Newer => Tone::Warn,
            Change::Install | Change::Update => Tone::Active,
        },
    );
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

fn erase_confirm(ui: &Ui, title: &str) -> Result<bool> {
    Ok(ui.choose(
        title,
        &[
            Item::new('c', "Cancel", "Keep board files"),
            Item::new('e', "Erase and install", "Deletes all board files").danger(),
        ],
        0,
        Some(0),
    )? == Some(1))
}

const ERASE: &str = "Erase the whole chip? All files will be deleted.";

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
        if last.is_none() {
            ui.field("connect", format!("{baud} baud"), Tone::Active);
        } else {
            ui.field("retry", format!("{baud} baud"), Tone::Muted);
        }
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
                log::warn!("Attempt at {baud} baud failed: {error:#}");
                last = Some(error);
            }
        }
    }
    Err(last.unwrap()).context("Flashing failed at every baud rate")
}

/// Selects the build for a board and shows the board with its plan.
/// Returns None when the user cancels the build choice.
fn prepare(
    target: Target,
    catalogs: &mut HashMap<String, (Builds, bool)>,
    catalog: &Catalog,
    args: &Args,
    options: FlashOptions<'_>,
    ui: &Ui,
) -> Result<Option<Job>> {
    show_target(&target, ui);
    let board = target.hardware.board.clone();
    if !catalogs.contains_key(&board) {
        if !args.offline {
            ui.live("firmware", "checking micropython.org");
        }
        catalogs.insert(board.clone(), catalog.builds(&board)?);
    }
    let (builds, online) = catalogs[&board].clone();
    let variant = if let Some(variant) = options.variant {
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
        match catalog::select_variant(&builds, &target.hardware.names(), online) {
            Ok(variant) => variant,
            Err(error) => {
                ui.warning(&error.to_string());
                if args.yes {
                    return Err(error);
                }
                let Some(variant) = choose_variant(ui, &builds, "")? else {
                    return Ok(None);
                };
                variant
            }
        }
    };
    let job = Job {
        target,
        builds,
        online,
        variant,
    };
    show_plan(&job, catalog, ui);
    Ok(Some(job))
}

/// Asks what to do with one board: a countdown to the planned action, then a menu on request.
fn decide(
    job: &mut Job,
    catalog: &Catalog,
    args: &Args,
    options: FlashOptions<'_>,
    ui: &Ui,
    title: &str,
    countdown: bool,
) -> Result<Action> {
    if args.yes {
        return Ok(job.default_action(options));
    }
    let mut automatic = countdown;
    loop {
        let needed = job.needed(options);
        let version = job.build().version;
        if automatic {
            let (action, seconds) = if !needed {
                ("Skipping".to_owned(), 3)
            } else if options.erase {
                (format!("Erasing and installing {version}"), 5)
            } else {
                (format!("Installing {version}"), 5)
            };
            if !ui.countdown(&action, seconds)? {
                if options.erase && needed && !erase_confirm(ui, ERASE)? {
                    return Ok(Action::Skip);
                }
                return Ok(job.default_action(options));
            }
        }
        automatic = false;
        let mut items = vec![
            Item::new('f', format!("Install {version}"), "Write firmware"),
            Item::new('e', "Erase and install", "Deletes all board files").danger(),
        ];
        if job.builds.len() > 1 {
            items.push(Item::new('v', "Choose build", "Select a firmware variant"));
        }
        items.push(Item::new('s', "Skip", "Keep the board as it is"));
        let skip = items.len() - 1;
        let choice = ui
            .choose(title, &items, if needed { 0 } else { skip }, Some(skip))?
            .unwrap_or(skip);
        match items[choice].key {
            's' => return Ok(Action::Skip),
            'v' => {
                if let Some(selected) = choose_variant(ui, &job.builds, &job.variant)? {
                    job.variant = selected;
                    show_plan(job, catalog, ui);
                }
            }
            'e' => {
                if erase_confirm(ui, ERASE)? {
                    return Ok(Action::Flash { erase: true });
                }
            }
            _ => return Ok(Action::Flash { erase: false }),
        }
    }
}

/// Asks once for several boards: one countdown to the whole plan, then a menu on request.
fn decide_all(
    jobs: &mut [Job],
    catalog: &Catalog,
    args: &Args,
    options: FlashOptions<'_>,
    ui: &Ui,
) -> Result<Vec<Action>> {
    let planned: Vec<_> = jobs.iter().map(|job| job.default_action(options)).collect();
    if args.yes {
        return Ok(planned);
    }
    let writes = jobs.iter().filter(|job| job.needed(options)).count();
    let (action, seconds) = if writes == 0 {
        ("Skipping all boards".to_owned(), 3)
    } else if options.erase {
        (
            format!(
                "Erasing and installing on {writes} of {} boards",
                jobs.len()
            ),
            5,
        )
    } else {
        (
            format!("Installing on {writes} of {} boards", jobs.len()),
            5,
        )
    };
    let choice = if ui.countdown(&action, seconds)? {
        let items = [
            Item::new(
                'a',
                "Apply the plan",
                format!("Write {writes}, skip {}", jobs.len() - writes),
            ),
            Item::new('b', "Choose per board", "Pick an action for each board"),
            Item::new('s', "Skip all", "Keep every board as it is"),
        ];
        ui.choose("Choose an action", &items, 0, Some(2))?
            .map_or('s', |i| items[i].key)
    } else {
        'a'
    };
    match choice {
        's' => Ok(vec![Action::Skip; jobs.len()]),
        'b' => jobs
            .iter_mut()
            .map(|job| {
                println!();
                let title = format!(
                    "{}: {} · {}",
                    job.port(),
                    job.change().label(),
                    build_name(job.board(), &job.variant)
                );
                decide(job, catalog, args, options, ui, &title, false)
            })
            .collect(),
        _ => {
            if options.erase
                && writes > 0
                && !erase_confirm(
                    ui,
                    "Erase the whole chip on each board? All files will be deleted.",
                )?
            {
                return Ok(vec![Action::Skip; jobs.len()]);
            }
            Ok(planned)
        }
    }
}

/// Writes the selected firmware and checks that the board runs it.
fn execute(job: &Job, erase: bool, catalog: &Catalog, args: &Args, ui: &Ui) -> Result<Outcome> {
    let board = job.board();
    let build = job.build();
    if !catalog.cache.join(&build.name).is_file() {
        ui.live("download", &build.name);
    }
    let path = catalog.firmware(board, build)?;
    ui.field(
        "file",
        format!(
            "{} · {}",
            build.name,
            ui::megabytes(std::fs::metadata(&path)?.len())
        ),
        Tone::Normal,
    );
    let image = image::Image::read(&path)?;
    let mut erase = erase;
    if !erase
        && job
            .target
            .running
            .as_ref()
            .is_some_and(|running| plan::files_move(board, running, &job.variant, image.filesystem))
    {
        if args.yes {
            bail!(
                "The new build may lose board files. Run interactively, or explicitly select flash --erase."
            );
        }
        if !erase_confirm(
            ui,
            &format!(
                "{}: the new build keeps board files elsewhere; they will be lost. Erase the whole chip?",
                job.port()
            ),
        )? {
            return Ok(Outcome::Skipped);
        }
        erase = true;
    }
    flash(&job.target, &path, erase, ui)?;
    ui.live("reboot", "waiting for the board");
    let port = wait_port(&job.target.port)?;
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
            plan::running_variant(board, &running) == Some(job.variant.as_str()),
            "The board reports build {}, expected {board}-{}",
            running.build,
            variant_name(&job.variant)
        );
    }
    if port.name != job.target.port.name {
        ui.field("port", format!("{} (reconnected)", port.name), Tone::Normal);
    }
    ui.field(
        "ready",
        format!("MicroPython {} is running", running.version),
        Tone::Good,
    );
    Ok(match job.change() {
        Change::Install => Outcome::Installed,
        Change::WrongBuild => Outcome::BuildFixed,
        Change::Update => Outcome::Updated,
        _ => Outcome::Reflashed,
    })
}

/// Shows a board's result and adds it to the run report.
fn record(
    ui: &Ui,
    report: &mut Vec<(String, Option<Outcome>)>,
    port: &str,
    result: Result<Outcome>,
    show: bool,
) {
    match result {
        Ok(outcome) => {
            if show {
                ui.field("result", outcome.label(), outcome.tone());
            }
            report.push((port.to_owned(), Some(outcome)));
        }
        Err(error) => {
            ui.error(&format!("{port}: {error:#}"));
            report.push((port.to_owned(), None));
        }
    }
}

fn run(args: &Args, root: &Path, ui: &Ui) -> Result<()> {
    if matches!(args.command, Some(Command::Probe)) {
        let (ports, _) = select_ports(args)?;
        ensure!(!ports.is_empty(), "No supported USB serial port was found");
        let (targets, failed) = read_targets(&ports, None, !args.port.is_empty());
        println!("{}", serde_json::to_string_pretty(&targets)?);
        ensure!(failed.is_empty(), "Could not read {} port(s)", failed.len());
        ensure!(!targets.is_empty(), "No ESP32 chip was detected");
        return Ok(());
    }
    if let Some(Command::Backup { output }) = &args.command {
        let (ports, _) = select_ports(args)?;
        ensure!(
            args.port.len() == 1 && ports.len() == 1,
            "For a backup, select exactly one port with --port"
        );
        let target = inspect(&ports[0])?;
        ui.field(
            "backup",
            format!("{} → {}", target.port.name, output.display()),
            Tone::Active,
        );
        Connected::open(&target.port, Some(921_600))?.backup(&target.hardware, output)?;
        ui.field("backup", "complete", Tone::Good);
        return Ok(());
    }
    let preview = matches!(args.command, Some(Command::Plan));
    ensure!(
        ui.interactive || args.yes || preview,
        "Use a terminal, or specify --yes. Use probe or plan to inspect boards without writing firmware."
    );
    let (ports, unknown) = select_ports(args)?;
    let (ports, mut unknown) = if !ports.is_empty() || !unknown.is_empty() {
        (ports, unknown)
    } else if ui.interactive && !args.yes {
        wait_board(ui)?
    } else if device::ports()?.iter().any(|port| port.firmware_usb) {
        bail!(
            "The board exposes only its firmware USB port. Hold BOOT, tap RESET, release BOOT and run again."
        );
    } else {
        bail!("No ESP32 adapter was found. Connect a board and run again.");
    };
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
    ui.live("scan", "reading USB serial ports");
    let (targets, failed) = read_targets(&ports, Some(ui), !args.port.is_empty());
    let detected = !targets.is_empty();
    let mut seen: HashSet<String> = targets
        .iter()
        .filter_map(|target| target.hardware.mac.clone())
        .collect();
    let mut report: Vec<(String, Option<Outcome>)> =
        failed.into_iter().map(|port| (port, None)).collect();
    let mut jobs = Vec::new();
    for target in targets {
        let port = target.port.name.clone();
        let job = prepare(target, &mut catalogs, &catalog, args, options, ui);
        match job {
            Ok(Some(job)) if preview => {
                let outcome = if job.change().needed() {
                    Outcome::WouldFlash
                } else {
                    Outcome::WouldSkip
                };
                record(ui, &mut report, &port, Ok(outcome), true);
            }
            Ok(Some(job)) => jobs.push(job),
            Ok(None) => record(ui, &mut report, &port, Ok(Outcome::Skipped), true),
            Err(error) => record(ui, &mut report, &port, Err(error), true),
        }
    }
    let actions = match jobs.len() {
        0 => Vec::new(),
        1 => vec![decide(
            &mut jobs[0],
            &catalog,
            args,
            options,
            ui,
            "Choose an action",
            true,
        )?],
        _ => decide_all(&mut jobs, &catalog, args, options, ui)?,
    };
    let several = jobs.len() > 1;
    for (job, action) in jobs.iter().zip(actions) {
        match action {
            Action::Skip => record(ui, &mut report, job.port(), Ok(Outcome::Skipped), !several),
            Action::Flash { erase } => {
                if several {
                    ui.section(job.port());
                }
                let result = execute(job, erase, &catalog, args, ui);
                record(ui, &mut report, job.port(), result, true);
            }
        }
    }
    while !unknown.is_empty() && ui.interactive && !args.yes && !preview {
        let mut items = vec![Item::new('c', "Close", "")];
        items.extend(unknown.iter().enumerate().map(|(i, port)| {
            Item::new(
                char::from_digit((i + 1) as u32, 10).unwrap_or('\0'),
                &port.name,
                "not a known ESP32 USB adapter",
            )
        }));
        println!();
        let choice = ui
            .choose("Try a port that was not probed?", &items, 0, Some(0))?
            .unwrap_or(0);
        if choice == 0 {
            break;
        }
        let port = unknown.remove(choice - 1);
        log::info!("Trying USB adapter {:04x}:{:04x}", port.vid, port.pid);
        match inspect(&port) {
            Ok(target) => {
                if let Some(mac) = &target.hardware.mac
                    && !seen.insert(mac.clone())
                {
                    ui.field("skip", "this board was already processed", Tone::Muted);
                    continue;
                }
                let result = (|| {
                    let Some(mut job) =
                        prepare(target, &mut catalogs, &catalog, args, options, ui)?
                    else {
                        return Ok(Outcome::Skipped);
                    };
                    match decide(
                        &mut job,
                        &catalog,
                        args,
                        options,
                        ui,
                        "Choose an action",
                        true,
                    )? {
                        Action::Skip => Ok(Outcome::Skipped),
                        Action::Flash { erase } => execute(&job, erase, &catalog, args, ui),
                    }
                })();
                record(ui, &mut report, &port.name, result, true);
            }
            Err(error) => ui.warning(&format!("{}: {error:#}", port.name)),
        }
    }
    if report.len() > 1 {
        let rows: Vec<_> = report
            .iter()
            .map(|(port, outcome)| match outcome {
                Some(outcome) => (port.clone(), outcome.label(), outcome.tone()),
                None => (port.clone(), "failed", Tone::Bad),
            })
            .collect();
        ui.summary(&rows, preview);
    }
    let failures = report
        .iter()
        .filter(|(_, outcome)| outcome.is_none())
        .count();
    if failures > 0 {
        return Err(Shown(failures).into());
    }
    if !detected && !ui.interactive {
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
            self_update::update(restart_args, ui.interactive, |text| {
                ui.field("tool", text, Tone::Active)
            })
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
    let mut result = run(&args, &root, &ui);
    let closed = result.as_ref().is_err_and(|error| error.is::<Closed>());
    if closed {
        result = Ok(());
    }
    if let Err(error) = &result {
        if let Some(Shown(failures)) = error.downcast_ref::<Shown>() {
            log::error!("{failures} board operation(s) failed");
        } else if matches!(args.command, Some(Command::Probe)) {
            eprintln!("{error:#}");
        } else {
            ui.error(&format!("{error:#}"));
        }
    }
    if !matches!(args.command, Some(Command::Probe)) && !closed {
        if let Some(path) = log_path {
            ui.line(&format!("log: {}", path.display()), Tone::Muted);
        }
        if !args.no_pause && ui::owns_window() {
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
    #[ignore = "Needs MICROPYTHON_ESP_FLASHER_HARDWARE_TEST=1 and MICROPYTHON_ESP_FLASHER_TEST_PORT; backs up and reflashes a real board"]
    fn hardware_reflash_preserves_all_files() -> Result<()> {
        ensure!(
            std::env::var("MICROPYTHON_ESP_FLASHER_HARDWARE_TEST").as_deref() == Ok("1"),
            "Set MICROPYTHON_ESP_FLASHER_HARDWARE_TEST=1 to permit a real flash"
        );
        let name = std::env::var("MICROPYTHON_ESP_FLASHER_TEST_PORT")
            .context("Set MICROPYTHON_ESP_FLASHER_TEST_PORT to the test board's port")?;
        let root = PathBuf::from(
            std::env::var("MICROPYTHON_ESP_FLASHER_DATA_DIR")
                .unwrap_or_else(|_| env!("CARGO_MANIFEST_DIR").into()),
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
        let marker = format!(
            "/.micropython-esp-flasher-smoke-{}-{stamp}",
            std::process::id()
        );
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
            let job = Job {
                target: target.clone(),
                builds: builds.clone(),
                online: false,
                variant: variant.clone(),
            };
            let options = FlashOptions {
                force: true,
                ..Default::default()
            };
            let Action::Flash { erase } = job.default_action(options) else {
                bail!("A forced flash must write firmware");
            };
            execute(&job, erase, &catalog, &args, &ui)?;
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
