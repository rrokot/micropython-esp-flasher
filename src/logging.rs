use chrono::Local;
use log::{LevelFilter, Log, Metadata, Record};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

struct Logger(Mutex<File>);

impl Log for Logger {
    fn enabled(&self, _: &Metadata<'_>) -> bool {
        true
    }
    fn log(&self, record: &Record<'_>) {
        if let Ok(mut file) = self.0.lock() {
            let _ = writeln!(
                file,
                "{} {:5} {}: {}",
                Local::now().format("%H:%M:%S%.3f"),
                record.level(),
                record.target(),
                record.args()
            );
        }
    }
    fn flush(&self) {
        if let Ok(mut file) = self.0.lock() {
            let _ = file.flush();
        }
    }
}

pub fn start(root: &Path) -> Option<PathBuf> {
    let dir = root.join("logs");
    fs::create_dir_all(&dir).ok()?;
    let mut logs: Vec<_> = fs::read_dir(&dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|path| path.is_file() && path.extension().is_some_and(|ext| ext == "log"))
        .collect();
    logs.sort();
    for path in logs.iter().take(logs.len().saturating_sub(29)) {
        let _ = fs::remove_file(path);
    }
    let path = dir.join(format!(
        "{}_rust_{}.log",
        Local::now().format("%Y-%m-%d_%H-%M-%S%.3f"),
        std::process::id()
    ));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .ok()?;
    log::set_logger(Box::leak(Box::new(Logger(Mutex::new(file))))).ok()?;
    log::set_max_level(LevelFilter::Debug);
    log::info!(
        "micropython-esp-flasher {} ({}/{})",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH
    );
    Some(path)
}
