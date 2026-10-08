use crate::image::Image;
use anyhow::{Context, Result, bail, ensure};
use regex::Regex;
use reqwest::blocking::Client;
use serde::Serialize;
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::LazyLock,
    time::Duration,
};

const SITE: &str = "https://micropython.org";
static VERSION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d+)\.(\d+)(?:\.(\d+))?").unwrap());

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
pub struct Version(pub u32, pub u32, pub u32);

impl Version {
    pub fn parse(text: &str) -> Option<Self> {
        let m = VERSION.captures(text)?;
        Some(Self(
            m[1].parse().ok()?,
            m[2].parse().ok()?,
            m.get(3).map_or(Some(0), |v| v.as_str().parse().ok())?,
        ))
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Build {
    pub name: String,
    pub variant: String,
    pub version: Version,
    pub date: String,
}

pub type Builds = BTreeMap<String, Build>;

pub fn parse_builds<'a>(board: &str, names: impl IntoIterator<Item = &'a str>) -> Builds {
    let pattern = Regex::new(&format!(
        r"^{}-(?:([A-Z0-9_]+)-)?(\d{{8}})-v(\d+\.\d+(?:\.\d+)?)\.bin$",
        regex::escape(board)
    ))
    .unwrap();
    let mut builds: Builds = BTreeMap::new();
    for name in names {
        let Some(m) = pattern.captures(name) else {
            continue;
        };
        let Some(version) = Version::parse(&m[3]) else {
            continue;
        };
        let build = Build {
            name: name.to_owned(),
            variant: m.get(1).map_or("", |m| m.as_str()).to_owned(),
            version,
            date: m[2].to_owned(),
        };
        if builds
            .get(&build.variant)
            .is_none_or(|old| (build.version, &build.date) > (old.version, &old.date))
        {
            builds.insert(build.variant.clone(), build);
        }
    }
    builds
}

pub fn cached_builds(cache: &Path, board: &str) -> Result<Builds> {
    let mut names = Vec::new();
    if !cache.exists() {
        return Ok(Builds::new());
    }
    for entry in fs::read_dir(cache)? {
        let entry = entry?;
        if entry.file_type()?.is_file() && entry.metadata()?.len() > 0 {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    Ok(parse_builds(board, names.iter().map(String::as_str)))
}

pub struct Catalog {
    client: Client,
    pub cache: PathBuf,
    offline: bool,
    site: String,
}

impl Catalog {
    pub fn new(root: &Path, offline: bool) -> Result<Self> {
        Ok(Self {
            client: Client::builder()
                .user_agent(concat!(
                    "micropython-esp-flasher/",
                    env!("CARGO_PKG_VERSION")
                ))
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(120))
                .build()?,
            cache: root.join("firmware"),
            offline,
            site: SITE.to_owned(),
        })
    }

    pub fn builds(&self, board: &str) -> Result<(Builds, bool)> {
        if !self.offline {
            let response = self
                .client
                .get(format!("{}/download/{board}/", self.site))
                .timeout(Duration::from_secs(15))
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.text());
            match response {
                Ok(html) => {
                    static LINKS: LazyLock<Regex> = LazyLock::new(|| {
                        Regex::new(r#"/resources/firmware/([^"'<>\s/]+\.bin)"#).unwrap()
                    });
                    let names: Vec<_> = LINKS
                        .captures_iter(&html)
                        .map(|m| m[1].to_owned())
                        .collect();
                    let builds = parse_builds(board, names.iter().map(String::as_str));
                    ensure!(
                        !builds.is_empty(),
                        "No stable generic firmware is available for {board}"
                    );
                    return Ok((builds, true));
                }
                Err(error) => log::warn!("Firmware catalog unavailable for {board}: {error}"),
            }
        }
        let builds = cached_builds(&self.cache, board)?;
        ensure!(
            !builds.is_empty(),
            "No cached firmware for {board}. Connect to the internet and run again."
        );
        Ok((builds, false))
    }

    pub fn firmware(&self, board: &str, build: &Build) -> Result<PathBuf> {
        fs::create_dir_all(&self.cache)?;
        let path = self.cache.join(&build.name);
        if path.is_file() && Image::read(&path).is_ok() {
            self.prune(board, Some(&build.name))?;
            return Ok(path);
        }
        ensure!(
            !self.offline,
            "Cached firmware is missing or invalid: {}",
            path.display()
        );
        let partial = path.with_extension("bin.part");
        let result = (|| -> Result<()> {
            let mut response = self
                .client
                .get(format!("{}/resources/firmware/{}", self.site, build.name))
                .send()?
                .error_for_status()?;
            let expected = response.content_length();
            let mut file = File::create(&partial)?;
            let written = io::copy(&mut response, &mut file)?;
            ensure!(
                written > 0 && expected.is_none_or(|size| size == written),
                "Incomplete firmware download"
            );
            file.flush()?;
            file.sync_all()?;
            drop(file);
            Image::read(&partial).context("Downloaded firmware is invalid")?;
            if path.exists() {
                fs::remove_file(&path)?;
            }
            fs::rename(&partial, &path)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&partial);
        }
        result?;
        self.prune(board, Some(&build.name))?;
        Ok(path)
    }

    fn prune(&self, board: &str, selected: Option<&str>) -> Result<()> {
        let newest = cached_builds(&self.cache, board)?;
        for entry in fs::read_dir(&self.cache)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if selected == Some(name.as_str()) {
                continue;
            }
            let old = parse_builds(board, [name.as_str()]);
            if let Some(build) = old.values().next()
                && newest
                    .get(&build.variant)
                    .is_some_and(|keep| keep.name != name)
                && let Err(error) = fs::remove_file(entry.path())
            {
                log::warn!("Cannot remove old firmware {name}: {error}");
            }
        }
        Ok(())
    }
}

pub fn select_variant(builds: &Builds, hardware: &[String], online: bool) -> Result<String> {
    let latest = builds
        .values()
        .map(|build| build.version)
        .max()
        .context("No firmware builds")?;
    let choice = builds
        .keys()
        .filter(|variant| {
            !variant.is_empty()
                && hardware.contains(variant)
                && (!online || builds[*variant].version == latest)
        })
        .max_by_key(|variant| variant.len());
    if let Some(choice) = choice {
        return Ok(choice.clone());
    }
    if builds.contains_key("") {
        return Ok(String::new());
    }
    bail!("The expected firmware build is not available")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_catalog_is_per_variant_and_version_then_date() {
        let names = [
            "ESP32_GENERIC_S3-20260824-v1.29.0.bin",
            "ESP32_GENERIC_S3-20260101-v1.28.0.bin",
            "ESP32_GENERIC_S3-20260901-v1.29.0.bin",
            "ESP32_GENERIC_S3-SPIRAM_OCT-20260824-v1.29.0.bin",
            "ESP32_GENERIC_S3-20261001-v1.30.0-preview.bin",
            "ESP32_GENERIC_S3-20261001-v1.30.0.bin.part",
            "ESP32_GENERIC-20260901-v1.29.0.bin",
            "ESP32_GENERIC_S3-20260824-v999999999999.0.bin",
        ];
        let builds = parse_builds("ESP32_GENERIC_S3", names);
        assert_eq!(builds.len(), 2);
        assert_eq!(builds[""].name, names[2]);
        assert_eq!(builds["SPIRAM_OCT"].version, Version(1, 29, 0));
    }

    #[test]
    fn variant_follows_hardware_and_ignores_retired_online_variants() {
        let builds = parse_builds(
            "ESP32_GENERIC",
            [
                "ESP32_GENERIC-20260824-v1.29.0.bin",
                "ESP32_GENERIC-SPIRAM-20260824-v1.29.0.bin",
                "ESP32_GENERIC-D2WD-20260101-v1.28.0.bin",
            ],
        );
        assert_eq!(
            select_variant(&builds, &["SPIRAM".into()], true).unwrap(),
            "SPIRAM"
        );
        assert_eq!(select_variant(&builds, &["D2WD".into()], true).unwrap(), "");
        assert_eq!(
            select_variant(&builds, &["D2WD".into()], false).unwrap(),
            "D2WD"
        );
        assert_eq!(
            select_variant(&builds, &["FLASH_4M".into()], true).unwrap(),
            ""
        );
    }

    #[test]
    fn octal_variant_beats_spiram_and_offline_can_use_only_octal() {
        let builds = parse_builds(
            "ESP32_GENERIC_S3",
            [
                "ESP32_GENERIC_S3-SPIRAM-20260824-v1.29.0.bin",
                "ESP32_GENERIC_S3-SPIRAM_OCT-20260824-v1.29.0.bin",
            ],
        );
        assert_eq!(
            select_variant(&builds, &["SPIRAM".into(), "SPIRAM_OCT".into()], false).unwrap(),
            "SPIRAM_OCT"
        );
        assert!(select_variant(&builds, &[], true).is_err());
    }

    #[test]
    fn offline_requires_nonempty_matching_cache() {
        let dir = tempfile::tempdir().unwrap();
        let cache = dir.path().join("firmware");
        fs::create_dir(&cache).unwrap();
        fs::write(cache.join("ESP32_GENERIC-20260824-v1.29.0.bin"), "x").unwrap();
        fs::write(cache.join("ESP32_GENERIC_S3-20260824-v1.29.0.bin"), "").unwrap();
        let catalog = Catalog::new(dir.path(), true).unwrap();
        assert!(catalog.builds("ESP32_GENERIC_S3").is_err());
        assert_eq!(catalog.builds("ESP32_GENERIC").unwrap().0.len(), 1);
    }

    #[test]
    fn cache_pruning_keeps_other_boards_previews_and_unrelated_files() {
        let dir = tempfile::tempdir().unwrap();
        let catalog = Catalog::new(dir.path(), true).unwrap();
        fs::create_dir(&catalog.cache).unwrap();
        let names = [
            "ESP32_GENERIC_S3-20260824-v1.29.0.bin",
            "ESP32_GENERIC_S3-20260101-v1.28.0.bin",
            "ESP32_GENERIC_S3-SPIRAM_OCT-20260101-v1.28.0.bin",
            "ESP32_GENERIC-20260101-v1.28.0.bin",
            "notes.txt",
            "ESP32_GENERIC_S3-20261001-v1.30.0-preview.bin",
        ];
        for name in names {
            fs::write(catalog.cache.join(name), "x").unwrap();
        }
        catalog.prune("ESP32_GENERIC_S3", None).unwrap();
        assert!(!catalog.cache.join(names[1]).exists());
        for name in [names[0], names[2], names[3], names[4], names[5]] {
            assert!(catalog.cache.join(name).exists());
        }
    }

    fn server(body: Vec<u8>, content_length: usize) -> (String, std::thread::JoinHandle<()>) {
        use std::{io::Read, net::TcpListener};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut request = [0; 4096];
            let _ = socket.read(&mut request).unwrap();
            write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {content_length}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            socket.write_all(&body).unwrap();
        });
        (url, handle)
    }

    fn firmware_bytes() -> Vec<u8> {
        let mut bytes = vec![0xff; 0x9000];
        bytes[0] = 0xe9;
        bytes[12..14].copy_from_slice(&9_u16.to_le_bytes());
        bytes[0x8000..0x8020].fill(0);
        bytes[0x8000..0x8003].copy_from_slice(&[0xaa, 0x50, 1]);
        bytes[0x8004..0x8008].copy_from_slice(&0x200000_u32.to_le_bytes());
        bytes[0x8008..0x800c].copy_from_slice(&0x100000_u32.to_le_bytes());
        bytes[0x800c..0x800f].copy_from_slice(b"vfs");
        bytes
    }

    #[test]
    fn preparing_an_older_selected_build_keeps_it_with_a_newer_cache() {
        let dir = tempfile::tempdir().unwrap();
        let catalog = Catalog::new(dir.path(), true).unwrap();
        fs::create_dir(&catalog.cache).unwrap();
        let names = [
            "ESP32_GENERIC_S3-20260824-v1.29.0.bin",
            "ESP32_GENERIC_S3-20260101-v1.28.0.bin",
        ];
        for name in names {
            fs::write(catalog.cache.join(name), firmware_bytes()).unwrap();
        }
        let builds = parse_builds("ESP32_GENERIC_S3", [names[1]]);
        let selected = catalog.firmware("ESP32_GENERIC_S3", &builds[""]).unwrap();
        assert!(selected.is_file());
        assert!(catalog.cache.join(names[0]).is_file());
    }

    #[test]
    fn downloads_only_complete_valid_images_and_reuses_cache_without_network() {
        let dir = tempfile::tempdir().unwrap();
        let mut catalog = Catalog::new(dir.path(), false).unwrap();
        let builds = parse_builds(
            "ESP32_GENERIC_S3",
            ["ESP32_GENERIC_S3-20260824-v1.29.0.bin"],
        );
        let build = &builds[""];
        for (body, size) in [
            (b"partial".to_vec(), 1024),
            (Vec::new(), 0),
            (b"bad image".to_vec(), 9),
        ] {
            let (url, handle) = server(body, size);
            catalog.site = url;
            assert!(catalog.firmware("ESP32_GENERIC_S3", build).is_err());
            handle.join().unwrap();
            assert_eq!(fs::read_dir(&catalog.cache).unwrap().count(), 0);
        }
        let bytes = firmware_bytes();
        let (url, handle) = server(bytes.clone(), bytes.len());
        catalog.site = url;
        let path = catalog.firmware("ESP32_GENERIC_S3", build).unwrap();
        handle.join().unwrap();
        assert_eq!(fs::read(&path).unwrap(), bytes);
        catalog.site = "http://127.0.0.1:1".into();
        assert_eq!(catalog.firmware("ESP32_GENERIC_S3", build).unwrap(), path);
    }

    #[test]
    fn online_catalog_overrides_old_cache_and_failed_request_uses_cache() {
        let dir = tempfile::tempdir().unwrap();
        let mut catalog = Catalog::new(dir.path(), false).unwrap();
        fs::create_dir(&catalog.cache).unwrap();
        fs::write(
            catalog.cache.join("ESP32_GENERIC_S3-20260101-v1.28.0.bin"),
            firmware_bytes(),
        )
        .unwrap();
        let html =
            br#"<a href="/resources/firmware/ESP32_GENERIC_S3-20260824-v1.29.0.bin">download</a>"#
                .to_vec();
        let (url, handle) = server(html.clone(), html.len());
        catalog.site = url;
        let (builds, online) = catalog.builds("ESP32_GENERIC_S3").unwrap();
        handle.join().unwrap();
        assert!(online);
        assert_eq!(builds[""].version, Version(1, 29, 0));
        catalog.site = "http://127.0.0.1:1".into();
        let (builds, online) = catalog.builds("ESP32_GENERIC_S3").unwrap();
        assert!(!online);
        assert_eq!(builds[""].version, Version(1, 28, 0));
    }
}
